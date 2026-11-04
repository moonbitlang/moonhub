// Read only: the controller must be stopped before the final readiness check.
const { DatabaseSync } = require('node:sqlite');
let db;
try {
  const providerName = process.argv[2];
  const allowIdle = process.argv[3] === '--allow-idle-workers';
  db = new DatabaseSync(process.env.DB_PATH || '/data/moonhub.db', {readOnly:true, timeout:5000});
  db.exec('BEGIN');
  const active = db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt WHERE status <> 'completed'").get().count;
  if (active) throw new Error(`${active} active attempts prevent production switch`);
  const provider = providerName && db.prepare('SELECT * FROM pipeline_provider WHERE name=?').get(providerName);
  if (provider && (provider.repository_scope !== 'all' || provider.revoked)) throw new Error('Production provider needs active all-repository authorization');
  if (allowIdle) {
    if (!provider || provider.mode !== 'asg' || !provider.paused) throw new Error('Production ASG provider must be paused before keeping idle workers');
    if (provider.config_revision !== provider.applied_revision) throw new Error('Production provider has unapplied configuration; drain workers before upgrading');
  }
  // Every provider can claim tasks against this Web process, including a
  // Docker provider running alongside the production ASG controller.
  const unpaused = db.prepare('SELECT COUNT(*) AS count FROM pipeline_provider WHERE revoked=0 AND paused=0').get().count;
  if (unpaused) throw new Error(`${unpaused} providers still accepting tasks`);
  const workers = db.prepare("SELECT w.state, w.provider_id, p.paused, p.revoked, p.config_revision, p.applied_revision FROM pipeline_worker w LEFT JOIN pipeline_provider p ON p.id=w.provider_id WHERE w.state NOT IN ('drained','failed')").all();
  const unsafe = workers.filter(worker => {
    if (provider && worker.provider_id === provider.id) return !allowIdle || worker.state === 'busy';
    // Other controllers are unchanged. Only a paused, fully configured idle
    // worker has acknowledged cleanup and can safely survive the Web switch.
    return !provider || worker.state !== 'ready' || !worker.paused || worker.revoked || worker.config_revision !== worker.applied_revision;
  }).length;
  if (unsafe) throw new Error(`${unsafe} workers still cleaning up or needing drain`);
  console.log('No active attempts; all providers paused and remaining workers safe for the switch.');
} catch (error) {
  console.error('Production upgrade refused: ' + error.message);
  process.exitCode = 1;
} finally { db?.close(); }
