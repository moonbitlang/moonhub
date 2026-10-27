// Disposable browser fixtures only; never opens a development or deployed DB.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const directory = mkdtempSync(join(tmpdir(), 'moonhub-browser-'));
const repos = join(directory, 'repos');
const database = join(directory, 'browser.db');
let server;
function cleanup() { rmSync(directory, { recursive: true, force: true }); }
process.on('exit', cleanup);
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.once(signal, () => {
    if (server && server.exitCode === null) server.kill('SIGTERM');
    else process.exit();
  });
}
try {
  mkdirSync(join(repos, 'alice'), { recursive: true });
  execFileSync('git', ['clone', '--bare', '--no-hardlinks', '--quiet',
    join(root, 'testdata/repos/alice/demo.git'), join(repos, 'alice/demo.git')]);
  cpSync(join(root, 'db'), join(directory, 'db'), { recursive: true });
  server = spawn(join(root, '_build/native/debug/build/hackwaly/moonhub/moonhub.exe'), [repos,
    '--assets', join(root, 'assets'), '--host', '127.0.0.1', '--port', '18092',
    '--root-user', 'browser-root', '--root-password', 'browser-test-password'], {
    cwd: directory, env: { ...process.env, DB_PATH: database, MAIL_OUTBOX_DIR: join(directory, 'mail') },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  server.stdout.pipe(process.stderr);
  server.stderr.pipe(process.stderr);
  server.on('error', error => { console.error(error); process.exit(1); });
  server.on('exit', code => process.exit(code ?? 0));
  let ready = false;
  for (let attempt = 0; attempt < 200; attempt++) {
    try {
      const response = await fetch('http://127.0.0.1:18092/-/login');
      await response.body?.cancel();
      if (response.ok) { ready = true; break; }
    } catch { /* Native server is still initializing. */ }
    await delay(100);
  }
  if (!ready) throw new Error('Browser fixture server did not start.');
  const db = new DatabaseSync(database);
  try {
    db.exec('PRAGMA foreign_keys = ON');
    // Reuse the freshly generated bootstrap hash; tests log in via the real route.
    const { password_hash } = db.prepare('SELECT password_hash FROM invitation WHERE kind = ?').get('root');
    db.prepare('INSERT INTO user (id, name_key, display_name, password_hash, is_site_admin) VALUES (1, ?, ?, ?, 1)').run('alice', 'Alice', password_hash);
    db.prepare('INSERT INTO user (id, name_key, display_name, password_hash) VALUES (2, ?, ?, ?)').run('outsider', 'Outside user', password_hash);
    db.exec(`INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'alice', 'Alice', 'personal');
      INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner');
      INSERT INTO repository (id, team_id, name, visibility, default_branch) VALUES (1, 1, 'demo', 'private', 'master');`);
  } finally { db.close(); }
  console.log('MoonHub browser fixture ready');
} catch (error) {
  console.error(error);
  server?.kill('SIGTERM');
  process.exitCode = 1;
}
