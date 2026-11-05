import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ActionRuntime } from './runtime.mjs';
import { validRelative, environment } from './platform.mjs';

const windows = process.platform === 'win32';
async function fixture(run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'moonhub Windows actions '));
  const workspace = path.join(root, 'workspace'), temp = path.join(root, 'temp');
  await fs.mkdir(workspace); await fs.mkdir(temp);
  const runtime = new ActionRuntime({ workspace, temp, repository: 'test/probe', sha: 'a'.repeat(40), server: 'https://moonhub.example',
    node20: path.resolve('.tmp/windows-runner/bin/node20.exe'), node24: process.execPath });
  try { await run(runtime, root); }
  finally { await fs.rm(root, { recursive: true, force: true }); }
}

test('Windows PowerShell defaults, exit codes and case-insensitive PATH exports', { skip: !windows }, async () => {
  await fixture(async runtime => {
    assert.equal(runtime.context().runner.os, 'Windows');
    assert.equal((await runtime.script("'answer=42' | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8")).outputs.answer, '42');
    assert.equal((await runtime.script("Write-Error 'expected failure'")).code, 1);
    assert.equal((await runtime.script('cmd /c exit 7')).code, 7);
    const result = await runtime.script("'Path=custom' | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8");
    assert.equal(result.code, 0);
    assert.equal(runtime.state.env.PATH, 'custom');
    assert.deepEqual(Object.keys(environment({Path:'a'}, {PATH:'b'})), ['PATH']);
    assert.equal(environment({Path:'a'}, {PATH:'b'}).PATH, 'b');
    for (const name of ['NUL', 'con.txt', 'file:stream', 'trailing.', 'trailing ', 'a/../b']) assert.equal(validRelative(name), false, name);
    assert.equal(validRelative('.'), true);
  });
});

test('Windows composite actions execute PowerShell and Git Bash with command files', { skip: !windows }, async () => {
  await fixture(async runtime => {
    const directory = path.join(runtime.workspace, 'action');
    await fs.mkdir(directory);
    await fs.writeFile(path.join(directory, 'action.yml'), `name: Windows composite
outputs:
  answer:
    value: \${{ steps.ps.outputs.answer }}
runs:
  using: composite
  steps:
    - id: ps
      shell: pwsh
      run: '"answer=42" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8'
    - shell: bash
      run: 'test "$RUNNER_OS" = Windows'
`);
    const result = await runtime.action('./action');
    assert.equal(result.code, 0);
    assert.equal(result.outputs.answer, '42');
  });
});

test('Windows JavaScript actions use the requested Node major and run post handlers', { skip: !windows }, async () => {
  await fixture(async runtime => {
    const directory = path.join(runtime.workspace, 'action');
    await fs.mkdir(directory);
    await fs.writeFile(path.join(directory, 'action.yml'), 'name: JS\nruns:\n  using: node20\n  main: main.cjs\n  post: post.cjs\n');
    await fs.writeFile(path.join(directory, 'main.cjs'), `require('node:assert/strict').equal(process.versions.node.split('.')[0], '20'); require('node:fs').appendFileSync(process.env.GITHUB_OUTPUT, 'os=' + process.env.RUNNER_OS + '\\n');`);
    await fs.writeFile(path.join(directory, 'post.cjs'), `require('node:fs').writeFileSync('post-ran', 'yes');`);
    const result = await runtime.action('./action');
    assert.equal(result.code, 0);
    assert.equal(result.outputs.os, 'Windows');
    assert.equal(await runtime.posts(), 0);
    assert.equal(await fs.readFile(path.join(runtime.workspace, 'post-ran'), 'utf8'), 'yes');
  });
});

test('Windows working directories cannot escape through a junction', { skip: !windows }, async () => {
  await fixture(async (runtime, root) => {
    const outside = path.join(root, 'outside'); await fs.mkdir(outside);
    await fs.symlink(outside, path.join(runtime.workspace, 'escape'), 'junction');
    await assert.rejects(runtime.script('Write-Output bad', '', 'escape'), /escapes/);
  });
});
