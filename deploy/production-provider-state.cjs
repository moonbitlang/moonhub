// Deployment owns the Web host, so no administrator token is needed here.
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
let db;
try {
  const [operation, argument] = process.argv.slice(2);
  db = new DatabaseSync(process.env.DB_PATH || '/data/moonhub.db', {timeout:5000});
  db.exec('BEGIN IMMEDIATE');
  if (operation === 'pause') {
    const query = db.prepare('SELECT id, name, paused, revoked, repository_scope FROM pipeline_provider WHERE name=?');
    query.setReadBigInts(true);
    const row = query.get(argument);
    if (row && (row.revoked !== 0n || row.repository_scope !== 'all')) throw new Error('Production provider needs active all-repository authorization');
    const active = db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt WHERE status <> 'completed'").get().count;
    if (active) throw new Error(`${active} active attempts prevent production switch`);
    const state = row ? {id:String(row.id), name:row.name, paused:Number(row.paused)} : {id:null, name:argument};
    // Write the recovery journal before committing the pause. If interrupted,
    // restoring this state is safe whether or not the transaction committed.
    fs.writeSync(1, JSON.stringify(state) + String.fromCharCode(10));
    if (row) db.prepare('UPDATE pipeline_provider SET paused=1 WHERE id=?').run(row.id);
  } else if (operation === 'restore') {
    const state = JSON.parse(argument);
    if (state.id !== null) {
      if (!/^[1-9][0-9]*$/.test(state.id) || ![0,1].includes(state.paused) || typeof state.name !== 'string') throw new Error('Invalid provider recovery state');
      const row = db.prepare('SELECT name, revoked FROM pipeline_provider WHERE id=?').get(BigInt(state.id));
      if (!row || row.name !== state.name || row.revoked) throw new Error('Provider identity changed; refusing to restore pause state');
      db.prepare('UPDATE pipeline_provider SET paused=? WHERE id=?').run(state.paused, BigInt(state.id));
    }
  } else {
    throw new Error('Expected pause NAME or restore STATE');
  }
  db.exec('COMMIT');
} catch (error) {
  try { db?.exec('ROLLBACK'); } catch {}
  console.error('Production provider state: ' + error.message);
  process.exitCode = 1;
} finally { db?.close(); }
