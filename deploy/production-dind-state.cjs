// Host deployment owns the stopped local controller; never read its credentials.
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
let db;
try {
  const [operation, name, argument, previousController] = process.argv.slice(2);
  const readOnly = operation === 'verify' || operation === 'current-image';
  db = new DatabaseSync(process.env.DB_PATH || '/data/moonhub.db', {readOnly, timeout:5000});
  db.exec(readOnly ? 'BEGIN' : 'BEGIN IMMEDIATE');
  const query = db.prepare('SELECT * FROM pipeline_provider WHERE name=?');
  query.setReadBigInts(true);
  const provider = query.get(name);
  if (!provider || provider.mode !== 'docker' || provider.revoked !== 0n) throw new Error('Expected the existing active Docker provider');
  const config = JSON.parse(provider.config_json);
  const inactive = () => {
    if (provider.paused !== 1n) throw new Error('Pause the Docker provider first');
    const active = db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt WHERE provider_id=? AND status<>'completed'").get(provider.id).count;
    if (active) throw new Error('Active Docker attempts prevent controller replacement');
  };
  if (operation === 'current-image') {
    if (typeof config.runner_image !== 'string' || !config.runner_image || /\s/.test(config.runner_image)) throw new Error('Docker provider has no valid saved runner image');
    console.log(config.runner_image);
  } else if (operation === 'retire') {
    // The caller stopped systemd and checked that no task container remains.
    inactive();
    db.prepare("UPDATE pipeline_worker SET state='drained',draining=1 WHERE provider_id=? AND state NOT IN ('drained','failed')").run(provider.id);
    db.prepare('UPDATE pipeline_provider SET controller_until_ms=0 WHERE id=?').run(provider.id);
    console.log(provider.controller_id || '');
  } else if (operation === 'image') {
    inactive();
    if (!argument || /\s/.test(argument)) throw new Error('Expected a task image');
    if (typeof config.runner_image !== 'string') throw new Error('Docker provider has no saved runner image');
    // Write the recovery record before committing, as with provider pause state.
    fs.writeSync(1, JSON.stringify({id:String(provider.id), name, previous_image:config.runner_image, installed_image:argument}) + '\n');
    if (config.runner_image !== argument) {
      config.runner_image = argument;
      db.prepare("UPDATE pipeline_provider SET config_json=?,config_revision=config_revision+1,control_status='pending' WHERE id=?").run(JSON.stringify(config), provider.id);
    }
  } else if (operation === 'restore-image') {
    inactive();
    const saved = JSON.parse(argument);
    if (saved.id !== String(provider.id) || saved.name !== name || typeof saved.previous_image !== 'string' || ![saved.previous_image,saved.installed_image].includes(config.runner_image)) throw new Error('Docker image changed since this recovery record');
    if (config.runner_image !== saved.previous_image) {
      config.runner_image = saved.previous_image;
      db.prepare("UPDATE pipeline_provider SET config_json=?,config_revision=config_revision+1,control_status='pending' WHERE id=?").run(JSON.stringify(config), provider.id);
    }
  } else if (operation === 'pause') {
    // Pausing stops new claims without interrupting an already running task.
    db.prepare('UPDATE pipeline_provider SET paused=1 WHERE id=?').run(provider.id);
  } else if (operation === 'verify') {
    if (config.runner_image !== argument || provider.observed_revision !== provider.config_revision || provider.controller_until_ms <= BigInt(Date.now())) throw new Error('Docker controller has not observed the deployed image');
    if (previousController && provider.controller_id === previousController) throw new Error('Previous Docker controller still owns the lease');
    if (provider.paused === 0n) {
      if (provider.applied_revision !== provider.config_revision || provider.control_status !== 'applied') throw new Error('Docker controller has not applied the deployed image');
      const worker = db.prepare("SELECT 1 FROM pipeline_worker WHERE provider_id=? AND worker_key=? AND state IN ('ready','busy') AND draining=0 AND applied_revision=? AND last_seen_ms>?").get(provider.id, 'docker-' + provider.controller_id, provider.config_revision, Date.now()-15000);
      if (!worker) throw new Error('Deployed Docker worker has not reported readiness');
    }
    console.log('Docker controller and saved task image match the deployed release.');
  } else {
    throw new Error('Expected current-image, retire, image, restore-image, pause or verify');
  }
  db.exec('COMMIT');
} catch (error) {
  try { db?.exec('ROLLBACK'); } catch {}
  console.error('Production Docker controller: ' + error.message);
  process.exitCode = 1;
} finally { db?.close(); }
