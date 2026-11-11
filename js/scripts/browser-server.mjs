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
  const git = (args, input) => execFileSync('git', ['--git-dir', join(repos, 'alice/demo.git'),
    '-c', 'user.name=Browser fixture', '-c', 'user.email=browser@moonhub.invalid', ...args],
    { encoding: 'utf8', input }).trim();
  // Dedicated ref for deep paths; the default fixture stays intact for other tests.
  const blob = git(['rev-parse', 'master:README.md']);
  let tree = git(['mktree'], `100644 blob ${blob}\tmain.mbt\n`);
  for (const name of ['a-very-long-directory-name-for-narrow-mobile-navigation', 'src']) {
    tree = git(['mktree'], `040000 tree ${tree}\t${name}\n`);
  }
  const commit = git(['commit-tree', tree, '-p', 'master', '-m', 'Nested browser fixture']);
  git(['update-ref', 'refs/heads/feature/breadcrumbs', commit]);
  git(['update-ref', 'refs/heads/release', 'master']);
  const diffTree = (value) => {
    const source = git(['hash-object', '-w', '--stdin'], value);
    const test = git(['hash-object', '-w', '--stdin'], 'test { assert_true(true) }\n');
    const api = git(['hash-object', '-w', '--stdin'], 'pub fn a() -> Int\n');
    return git(['mktree'], `100644 blob ${source}\tmain.mbt\n100644 blob ${test}\tmain_test.mbt\n100644 blob ${api}\tpkg.generated.mbti\n`);
  };
  const diffBase = git(['commit-tree', diffTree('fn a() { 1 }\n\n///|\nfn b() { 2 }\n'), '-p', 'master', '-m', 'MoonDiff base']);
  const diffHead = git(['commit-tree', diffTree('fn b() { 3 }\n\n///|\nfn a() { 1 }\n'), '-p', diffBase, '-m', 'MoonDiff reordered declarations']);
  git(['update-ref', 'refs/heads/moondiff-base', diffBase]);
  git(['update-ref', 'refs/heads/moondiff-feature', diffHead]);
  const singleTree = (files) => git(['mktree'], Object.entries(files).map(([name, value]) =>
    `${name === 'metadata.txt' && value.startsWith('after') ? '100755' : '100644'} blob ${git(['hash-object', '-w', '--stdin'], value)}\t${JSON.stringify(name)}\n`).join(''));
  const stable = 'fn stable() -> Int { 1 }\n';
  const singleBase = git(['commit-tree', singleTree({
    'deleted.mbt': 'fn removed_file() -> Int { 42 }\n',
    'deleted.txt': 'removed text\n\nlast removed line\n',
    'declarations.mbt': stable + '\n///|\nstruct Removed {\n  value : Int\n}\n',
    'metadata.txt': 'before\r\n',
  }), '-p', 'master', '-m', 'One-sided diff base']);
  const singleFiles = {
    'added.mbt': 'fn added_file() -> Int { 7 }\n\n///|\nfn another() -> String { "hello" }\n',
    'added.txt': 'added text\n\n' + 'long '.repeat(100) + '\n',
    'empty-added.txt': '',
    'blank-added.txt': '\n',
    'added_test.mbt': 'test { assert_true(true) }\n',
    'declarations.mbt': stable + '\n///|\nenum Added {\n  Ready\n}\n',
    'metadata.txt': 'after\nlast line',
  };
  const singleHead = git(['commit-tree', singleTree(singleFiles), '-p', singleBase, '-m', 'MoonDiff single-sided files and declarations']);
  const { 'empty-added.txt': emptyFile, ...withoutEmpty } = singleFiles;
  const emptyDeleted = git(['commit-tree', singleTree(withoutEmpty), '-p', singleHead, '-m', 'MoonDiff deleted empty file']);
  git(['update-ref', 'refs/heads/moondiff-empty-delete', emptyDeleted]);
  git(['update-ref', 'refs/heads/moondiff-single-base', singleBase]);
  git(['update-ref', 'refs/heads/moondiff-single', singleHead]);
  const syntaxFiles = {
    'sample.js': '// after comment\nconst message = "after";\n',
    'sample.ts': '// after comment\nconst message: string = "after";\n',
    'sample.tsx': '// after comment\nconst view = <div title="after">after</div>;\n',
    'sample.json': '{"message": "after", "enabled": true}\n',
    'sample.yaml': '# after comment\nmessage: "after"\nenabled: true\n',
    'sample.py': '# after comment\ndef greet():\n    return "after"\n',
    'sample.sh': '# after comment\nif true; then\n  echo "after"\nfi\n',
    'sample.mbt': '// after comment\nfn greet() -> String { "after" }\n',
    'sample.mbti': '// after comment\npub fn greet_after() -> String\n',
    'sample.unknown': '// after comment\nconst message = "after";\n',
    'sample.txt': '// after comment\nconst message = "after";\n',
    'another.js': '// after comment\nconst message = "after";\n',
  };
  const syntaxBase = git(['commit-tree', singleTree(Object.fromEntries(Object.entries(syntaxFiles).map(([name, text]) => [name, text.replaceAll('after', 'before')]))), '-p', 'master', '-m', 'Syntax highlighting base']);
  const syntaxHead = git(['commit-tree', singleTree(syntaxFiles), '-p', syntaxBase, '-m', 'Syntax highlighting languages']);
  git(['update-ref', 'refs/heads/moondiff-syntax', syntaxHead]);
  const pagedOld = Object.fromEntries(Array.from({ length: 105 }, (_, i) => [`a-${100 + i}.txt`, 'before\n']));
  const pagedNew = Object.fromEntries(Array.from({ length: 105 }, (_, i) => [`a-${100 + i}.txt`, 'after\n']));
  const moved = 'moved source\nline two\nline three\nline four\nline five\nline six\n';
  const pagedBase = git(['commit-tree', singleTree({ ...pagedOld, 'z-delete.txt': 'removed\n', 'z-old.txt': moved }), '-p', 'master', '-m', 'Paged browser base']);
  const validTree = singleTree({ ...pagedNew, 'z-add.txt': 'added source\n', 'z-new.txt': moved.replace('moved', 'changed'), '"bad-\\xff"': 'valid escape-like name\n' });
  const invalidBlob = git(['hash-object', '-w', '--stdin'], 'invalid path source\n');
  const validEntries = execFileSync('git', ['--git-dir', join(repos, 'alice/demo.git'), 'ls-tree', '-z', validTree]);
  const invalidEntries = Buffer.concat([0xff, 0xfe].map(byte => Buffer.concat([Buffer.from(`100644 blob ${invalidBlob}\tbad-`), Buffer.from([byte, 0])])));
  const pagedTree = git(['mktree', '-z'], Buffer.concat([validEntries, invalidEntries]));
  const pagedHead = git(['commit-tree', pagedTree, '-p', pagedBase, '-m', 'Paged browser changes']);
  git(['update-ref', 'refs/heads/moondiff-paged-base', pagedBase]);
  git(['update-ref', 'refs/heads/moondiff-paged', pagedHead]);
  const longLineSource = (version) => '///|\nfn greeting(name : String) -> String {\n' +
    `  let message = "${`${version} long message `.repeat(20)}END-${version}"\n` +
    '  message + name\n}\n';
  const longLineBase = git(['commit-tree', singleTree({
    'long-lines.mbt': longLineSource('before'),
    'ignored.mbt': '///|\n// before comment\nfn value() -> Int { 1 }\n',
    'shifted.txt': 'shared header\nremove me\nshared middle\nshared tail\n',
  }), '-p', 'master', '-m', 'Long lines base']);
  const longLineHead = git(['commit-tree', singleTree({
    'long-lines.mbt': longLineSource('after'),
    'ignored.mbt': '///|\n// after comment\nfn value() -> Int { 2 }\n',
    'shifted.txt': 'shared header\ninsert one\ninsert two\nshared middle\nshared tail\n',
  }), '-p', longLineBase, '-m', 'MoonDiff two-sided long lines']);
  git(['update-ref', 'refs/heads/moondiff-long-lines', longLineHead]);
  // Separated edits in each declaration and in plain text. Different
  // natural line widths catch per-row clamping instead of shared translation.
  const scrollDeclaration = (name, version) => `///|\nfn ${name}() -> String {\n` +
    Array.from({ length: 24 }, (_, i) => `  let value${i} = "${[0, 1, 20].includes(i) ? `${version} ${'long code '.repeat(i === 1 ? 25 : 12)}END-${i}` : `stable-${i}`}"\n`).join('') +
    '  value0\n}\n';
  const scrollFiles = version => ({
    'grouped.mbt': scrollDeclaration('first', version) + '\n' + scrollDeclaration('second', version),
    'groups.txt': Array.from({ length: 30 }, (_, i) => [1, 26].includes(i) ? `${version} ${'plain text '.repeat(30)}END-${i}\n` : `stable text ${i}\n`).join(''),
    'new-only.txt': version === 'before' ? 'a\n' : 'after '.repeat(90) + '\n',
    'old-only.txt': version === 'after' ? 'b\n' : 'before '.repeat(90) + '\n',
    'short.txt': version === 'after' ? 'b\n' : 'a\n',
  });
  const scrollBase = git(['commit-tree', singleTree(scrollFiles('before')), '-p', 'master', '-m', 'Block scroll base']);
  const scrollHead = git(['commit-tree', singleTree(scrollFiles('after')), '-p', scrollBase, '-m', 'MoonDiff block scrolling']);
  git(['update-ref', 'refs/heads/moondiff-scroll-base', scrollBase]);
  git(['update-ref', 'refs/heads/moondiff-scroll', scrollHead]);
  const reviewSource = (version) => '///|\nfn review() -> Int {\n' +
    Array.from({ length: 135 }, (_, i) => `  let value${i} = ${i + version}\n`).join('') + '  value134\n}\n';
  const reviewBase = git(['commit-tree', singleTree({ 'main.mbt': reviewSource(0), 'other.txt': 'before\n' }), '-p', 'master', '-m', 'Inline review base']);
  const reviewHead = git(['commit-tree', singleTree({ 'main.mbt': reviewSource(1), 'other.txt': 'after\n' }), '-p', reviewBase, '-m', 'Inline review long file']);
  git(['update-ref', 'refs/heads/moondiff-review-base', reviewBase]);
  git(['update-ref', 'refs/heads/moondiff-review', reviewHead]);
  execFileSync('git', ['clone', '--bare', '--no-hardlinks', '--quiet', join(repos, 'alice/demo.git'), join(repos, 'alice/public.git')]);
  cpSync(join(root, 'db'), join(directory, 'db'), { recursive: true });
  server = spawn(join(root, '_build/native/debug/build/moonhub.exe'), [repos,
    '--assets', join(root, 'assets'), '--host', '127.0.0.1', '--port', '18092',
    '--root-user', 'browser-root', '--root-password', 'browser-test-password'], {
    cwd: directory, env: { ...process.env, MOONHUB_DIFF_WORKER: join(root, '_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe'), DB_PATH: database, MAIL_OUTBOX_DIR: join(directory, 'mail') },
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
      INSERT INTO repository (id, team_id, name, visibility, default_branch) VALUES (1, 1, 'demo', 'private', 'master'), (2, 1, 'public', 'public', 'master');`);
  } finally { db.close(); }
  console.log('MoonHub browser fixture ready');
} catch (error) {
  console.error(error);
  server?.kill('SIGTERM');
  process.exitCode = 1;
}
