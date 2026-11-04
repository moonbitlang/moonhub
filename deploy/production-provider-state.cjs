// Deployment owns the Web host, so no administrator token is needed here.
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
let db;
try {
  const [operation, argument] = process.argv.slice(2);
  db = new DatabaseSync(process.env.DB_PATH || '/data/moonhub.db', {timeout:5000});
  db.exec('BEGIN IMMEDIATE');
  if (operation === 'pause' || operation === 'pause-all') {
    const query = db.prepare('SELECT id, name, paused, revoked, repository_scope FROM pipeline_provider WHERE name=?');
    query.setReadBigInts(true);
    const row = query.get(argument);
    if (row && (row.revoked !== 0n || row.repository_scope !== 'all')) throw new Error('Production provider needs active all-repository authorization');
    const active = db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt WHERE status <> 'completed'").get().count;
    if (active) throw new Error(`${active} active attempts prevent production switch`);
    const queryAll = db.prepare('SELECT id, name, paused FROM pipeline_provider WHERE revoked=0 ORDER BY id');
    queryAll.setReadBigInts(true);
    const providers = operation === 'pause-all' ? queryAll.all() : row ? [row] : [];
    const states = providers.map(p => ({id:String(p.id), name:p.name, paused:Number(p.paused)}));
    const state = operation === 'pause-all' ? {providers:states} : states[0] || {id:null, name:argument};
    // Write the recovery journal before committing the pause. If interrupted,
    // restoring this state is safe whether or not the transaction committed.
    fs.writeSync(1, JSON.stringify(state) + String.fromCharCode(10));
    for (const provider of providers) db.prepare('UPDATE pipeline_provider SET paused=1 WHERE id=?').run(provider.id);
  } else if (operation === 'restore') {
    const state = JSON.parse(argument);
    // Accept legacy single-provider journals as well as a complete pause set.
    const states = state && Object.hasOwn(state, 'providers') ? state.providers : [state];
    if (!Array.isArray(states)) throw new Error('Invalid provider recovery state');
    const ids = new Set();
    for (const saved of states) {
      if (saved?.id === null && !Object.hasOwn(state, 'providers')) continue;
      if (!saved || typeof saved.id !== 'string' || !/^[1-9][0-9]*$/.test(saved.id) || ![0,1].includes(saved.paused) || typeof saved.name !== 'string' || ids.has(saved.id)) throw new Error('Invalid provider recovery state');
      ids.add(saved.id);
      const row = db.prepare('SELECT name, revoked FROM pipeline_provider WHERE id=?').get(BigInt(saved.id));
      if (!row || row.name !== saved.name || row.revoked) throw new Error('Provider identity changed; refusing to restore pause state');
      db.prepare('UPDATE pipeline_provider SET paused=? WHERE id=?').run(saved.paused, BigInt(saved.id));
    }
  } else {
    throw new Error('Expected pause NAME, pause-all NAME or restore STATE');
  }
  db.exec('COMMIT');
} catch (error) {
  try { db?.exec('ROLLBACK'); } catch {}
  console.error('Production provider state: ' + error.message);
  process.exitCode = 1;
} finally { db?.close(); }
