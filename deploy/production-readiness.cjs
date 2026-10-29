// Read only: the controller must be stopped before the final readiness check.
const { DatabaseSync } = require('node:sqlite');
let db;
try {
  const providerName = process.argv[2];
  const allowIdle = process.argv[3] === '--allow-idle-workers';
  db = new DatabaseSync(process.env.DB_PATH || '/data/moonhub.db', {readOnly:true, timeout:5000});
  db.exec('BEGIN');
  const active = db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt WHERE status <> 'completed'").get().count;
  const workers = db.prepare("SELECT COUNT(*) AS count FROM pipeline_worker WHERE state NOT IN ('drained', 'failed')").get().count;
  if (active || (!allowIdle && workers)) throw new Error(`${active} active attempts, ${workers} undrained workers`);
  const provider = providerName && db.prepare('SELECT * FROM pipeline_provider WHERE name=?').get(providerName);
  if (provider && (provider.repository_scope !== 'all' || provider.revoked)) throw new Error('Production provider needs active all-repository authorization');
  if (allowIdle) {
    if (!provider || provider.mode !== 'asg' || !provider.paused) throw new Error('Production ASG provider must be paused before keeping idle workers');
    if (provider.config_revision !== provider.applied_revision) throw new Error('Production provider has unapplied configuration; drain workers before upgrading');
    // Busy can mean task-container cleanup is still in progress. Other
    // providers are not paused by this deployment and must already be drained.
    const unsafe = db.prepare("SELECT COUNT(*) AS count FROM pipeline_worker WHERE state NOT IN ('drained','failed') AND (state='busy' OR provider_id<>?)").get(provider.id).count;
    if (unsafe) throw new Error(`${unsafe} workers still cleaning up or belonging to another provider`);
  }
  console.log(allowIdle ? 'No active attempts; paused idle workers can remain.' : 'No active attempts or undrained standalone workers.');
} catch (error) {
  console.error('Production upgrade refused: ' + error.message);
  process.exitCode = 1;
} finally { db?.close(); }
