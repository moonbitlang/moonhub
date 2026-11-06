import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { ActionRuntime, execute, metadata, resolveJobOutputs } from './runtime.mjs';
import { evaluate, interpolate, evaluateAsync, interpolateAsync } from './expression.mjs';
import { parseFileCommands, LogCommands } from './commands.mjs';
import { reference, extractArchive } from './download.mjs';

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'moonhub-actions-test-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const workspace = path.join(root, 'workspace'), temp = path.join(root, 'tmp');
  await fs.mkdir(workspace); await fs.mkdir(temp);
  const config = { workspace, temp, repository: 'alice/demo', sha: 'a'.repeat(40), server: 'https://moonhub.example', node20: process.execPath };
  return { root, config, runtime: new ActionRuntime(config) };
}
async function action(config, name, yaml, scripts = {}) {
  const dir = path.join(config.workspace, name); await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, 'action.yml'), yaml);
  for (const [filename, text] of Object.entries(scripts)) await fs.writeFile(path.join(dir, filename), text);
  return './' + name;
}

test('expressions parse without JavaScript evaluation and interpolate once', () => {
  const context = { inputs: { name: "x'$(touch escaped)" }, steps: { build: { outputs: { version: '1.2.3' } } } };
  assert.equal(evaluate("inputs.name != '' && !failure()", context), true);
  assert.equal(evaluate("false && fromJSON('invalid') || 'fallback'", context), 'fallback');
  assert.equal(interpolate('v${{ steps.build.outputs.version }}-${{ inputs.name }}', context), "v1.2.3-x'$(touch escaped)");
  assert.equal(interpolate('${{ inputs.x }}', { inputs: { x: '${{ inputs.secret }}' } }), '${{ inputs.secret }}');
  for (const expression of ['process.exit()', 'inputs.constructor', 'inputs[true]', 'true;process.exit()', 'unknown()']) assert.throws(() => evaluate(expression, context));
});

test('file commands retain multiline/CRLF values and reject malformed input', () => {
  assert.deepEqual({ ...parseFileCommands('ONE=first=second\r\nMULTI<<END\r\na\r\nb\r\nEND\r\n') }, { ONE: 'first=second', MULTI: 'a\nb' });
  for (const text of ['X<<END\nvalue', 'X<<\n', '=bad', 'bare', 'X=\0']) assert.throws(() => parseFileCommands(text));
});

test('log commands mask split UTF-8 and overlapping masks before output', () => {
  const state = { masks: [] }, output = [], result = { outputs: {}, state: {} };
  const log = new LogCommands(state, text => output.push(text), result);
  const bytes = Buffer.from('::add-mask::密钥token\n::add-mask::token-extra\n密钥token-extra\n::set-output name=answer::yes\n');
  for (const byte of bytes) log.write(Buffer.from([byte]));
  log.end();
  assert.equal(output.join(''), '***\n'); assert.equal(result.outputs.answer, 'yes');
});

test('JavaScript actions receive inputs, environment, state, outputs and LIFO posts', async t => {
  const { config, runtime } = await fixture(t);
  const uses = await action(config, 'javascript', `name: Test
inputs:
  who:
    default: world
runs:
  using: node24
  pre: pre.cjs
  main: main.cjs
  post: post.cjs
`, {
    'pre.cjs': `require('fs').appendFileSync(process.env.GITHUB_STATE, 'from_pre=ready\\n');`,
    'main.cjs': `const fs=require('fs'); if(process.env.STATE_from_pre!=='ready')process.exit(2); fs.appendFileSync(process.env.GITHUB_ENV,'EXPORTED=value\\n'); fs.appendFileSync(process.env.GITHUB_PATH,process.env.GITHUB_WORKSPACE+'/bin\\n'); fs.appendFileSync(process.env.GITHUB_OUTPUT,'greeting=hello '+process.env.INPUT_WHO+'\\n'); fs.appendFileSync(process.env.GITHUB_STATE,'from_main='+process.env.INPUT_WHO+'\\n');`,
    'post.cjs': `require('fs').appendFileSync(process.env.GITHUB_WORKSPACE+'/posts', process.env.STATE_from_main+'\\n');`,
  });
  const first = await runtime.action(uses, { who: 'one' });
  assert.equal(first.code, 0); assert.equal(first.outputs.greeting, 'hello one');
  const second = await runtime.action(uses, { who: 'two' }); assert.equal(second.code, 0);
  assert.equal(runtime.state.env.EXPORTED, 'value');
  const script = await runtime.script('test "$EXPORTED" = value; test "${PATH%%:*}" = "$GITHUB_WORKSPACE/bin"; test -z "${INPUT_WHO:-}"', 'bash');
  assert.equal(script.code, 0); assert.equal(await runtime.posts(), 0);
  assert.equal(await fs.readFile(path.join(config.workspace, 'posts'), 'utf8'), 'two\none\n');
  assert.equal(await runtime.posts(), 0);
});

test('nested composite actions expose inputs and outputs and preserve file commands', async t => {
  const { config, runtime } = await fixture(t);
  const nested = await action(config, 'nested', `name: Nested
inputs:
  message:
    default: hello
outputs:
  message:
    value: \${{ steps.echo.outputs.message }}
runs:
  using: composite
  steps:
    - id: echo
      shell: bash
      env:
        MESSAGE: \${{ inputs.message }}
      run: echo "message=$MESSAGE" >> "$GITHUB_OUTPUT"
`);
  const outer = await action(config, 'outer', `name: Outer
outputs:
  result:
    value: \${{ steps.child.outputs.message }}
runs:
  using: composite
  steps:
    - id: child
      uses: ${nested}
      with:
        message: nested-value
    - if: steps.child.outputs.message == 'nested-value'
      shell: sh
      run: echo OUTER=ready >> "$GITHUB_ENV"
`);
  const result = await runtime.action(outer);
  assert.equal(result.code, 0); assert.equal(result.outputs.result, 'nested-value'); assert.equal(runtime.state.env.OUTER, 'ready');
});

test('failed main still registers cleanup and post-if sees job failure', async t => {
  const { config, runtime } = await fixture(t);
  const uses = await action(config, 'failure', `runs:
  using: node20
  main: main.cjs
  post: post.cjs
  post-if: failure()
`, { 'main.cjs': 'process.exit(7);', 'post.cjs': `require('fs').writeFileSync(process.env.GITHUB_WORKSPACE+'/cleaned','yes');` });
  assert.equal((await runtime.action(uses)).code, 7); runtime.failure = true; assert.equal(await runtime.posts(), 0);
  assert.equal(await fs.readFile(path.join(config.workspace, 'cleaned'), 'utf8'), 'yes');
});

test('unsafe metadata, runtime and file command paths fail explicitly', async t => {
  const { config, runtime } = await fixture(t);
  for (const [name, yaml] of Object.entries({ docker: 'runs: {using: docker, image: Dockerfile}', duplicate: 'runs: {using: node24, main: main.cjs, main: other.cjs}', alias: 'runs: &a {using: node24, main: main.cjs}', unknown: 'runs: {using: node24, main: main.cjs, unknown: yes}', deep: 'extra: ' + '['.repeat(1000) + '0' + ']'.repeat(1000) + '\nruns: {using: node24, main: main.cjs}' })) {
    const uses = await action(config, name, yaml); await assert.rejects(runtime.action(uses));
  }
  const unsafe = await action(config, 'unsafe', 'runs: {using: node24, main: main.cjs}', { 'main.cjs': `require('fs').appendFileSync(process.env.GITHUB_ENV,'NODE_OPTIONS=--require=evil\\n');` });
  await assert.rejects(runtime.action(unsafe), /unsafe action environment/);
  const escaping = await action(config, 'escaping', 'runs: {using: node24, main: ../outside.cjs}');
  await assert.rejects(runtime.action(escaping), /escapes/);
});

test('remote action references reject URL, path, ref and shell injection', () => {
  assert.deepEqual(reference('actions/cache/restore@v4'), { repository: 'actions/cache', path: 'restore', ref: 'v4' });
  for (const value of ['https://github.com/actions/cache@v4', 'a/b/../evil@v1', 'a/b@--upload-pack=evil', 'a/b@x;echo', 'a/b@foo..bar', 'a/b@', 'a/b@x@evil', 'a/b//nested@v1']) assert.throws(() => reference(value), value);
});

test('real tar archives extract bounded files and reject links', async t => {
  const { root } = await fixture(t);
  const source = path.join(root, 'archive-root'); await fs.mkdir(source); await fs.writeFile(path.join(source, 'action.yml'), 'runs: {using: node24, main: main.cjs}');
  const bytes = execFileSync('tar', ['--format=ustar', '--no-xattrs', '-cf', '-', '-C', root, 'archive-root'], { env: { ...process.env, COPYFILE_DISABLE: '1' } });
  await extractArchive(bytes, path.join(root, 'extracted'));
  assert.match(await fs.readFile(path.join(root, 'extracted/action.yml'), 'utf8'), /node24/);
  await fs.symlink('/etc/passwd', path.join(source, 'unsafe'));
  await assert.rejects(extractArchive(execFileSync('tar', ['--format=ustar', '--no-xattrs', '-cf', '-', '-C', root, 'archive-root'], { env: { ...process.env, COPYFILE_DISABLE: '1' } }), path.join(root, 'unsafe-extracted')), /regular files/);
});

test('top-level steps pass outputs through with/env/run, skip after failures and retain outcome', async t => {
  const { config } = await fixture(t);
  const make = (id, run = '', templates = {}, other = {}) => ({ ...config, step: { id, run, shell: 'bash', working_directory: '.', env: {}, inputs: {}, secret_env: {}, templates, ...other } });
  let state = (await execute(make('first', `echo 'value=ready' >> "$GITHUB_OUTPUT"`))).state;
  const uses = await action(config, 'consumer', `inputs: {message: {}}
runs: {using: node24, main: main.cjs}`, { 'main.cjs': `const fs=require('fs'); if(process.env.INPUT_MESSAGE!=='ready')process.exit(3); fs.appendFileSync(process.env.GITHUB_OUTPUT, 'consumed=yes\\n');` });
  let result = await execute(make('consumer', '', {'with:message': '${{ steps.first.outputs.value }}'}, {remote: true, uses, inputs: {message: ''}}), state);
  assert.equal(result.code, 0); state = result.state;
  result = await execute(make('script', '', {'env:VALUE': '${{ steps.consumer.outputs.consumed }}', run: 'test "$VALUE" = yes; test "${{ steps.first.outputs.value }}" = ready'}), state);
  assert.equal(result.code, 0);
  result = await execute(make('allowed', 'exit 7', {'continue-on-error': 'true'}), state);
  assert.equal(result.code, 0); assert.equal(state.steps.allowed.outcome, 'failure'); assert.equal(state.failure, false);
  result = await execute(make('fail', 'exit 7'), state); assert.equal(result.code, 7);
  result = await execute(make('skip', 'exit 99'), state); assert.equal(result.code, 0); assert.equal(result.conclusion, 'skipped');
  result = await execute(make('implicit', 'exit 99', {if: "steps.first.outputs.value == 'ready'"}), state); assert.equal(result.conclusion, 'skipped');
  result = await execute(make('always', 'echo done > finished', {if: 'always()'}), state); assert.equal(result.code, 0); assert.equal(state.failure, true);
  assert.equal(await fs.readFile(path.join(config.workspace, 'finished'), 'utf8'), 'done\n');
  assert.equal(evaluate("'always()' == 'always()'", { failure: true }, true), false);
});

test('runtime state is authenticated, encrypted and the private key does not reach actions', async t => {
  const { root, config } = await fixture(t);
  const { encodeState, decodeState } = await import('./state.mjs');
  const key = 'a'.repeat(64), state = { env: {TOKEN: 'sensitive-value'}, posts: [] };
  const encoded = encodeState(state, key);
  assert.ok(!encoded.includes('sensitive-value')); assert.deepEqual(decodeState(encoded, key), state);
  assert.throws(() => decodeState(encoded, 'b'.repeat(64)));
  const plan = path.join(root, 'plan.json'), stateFile = path.join(root, 'state');
  await fs.writeFile(plan, JSON.stringify({...config, step: { id: 'verify', run: 'test -z "${MOONHUB_ACTION_STATE_KEY:-}"; echo MARK=value >> "$GITHUB_ENV"', shell:'bash', env:{}, working_directory:'.' }}));
  execFileSync(process.execPath, [new URL('./runtime.mjs', import.meta.url).pathname, plan, stateFile], {env:{...process.env, MOONHUB_ACTION_STATE_KEY:key}});
  assert.equal(decodeState(await fs.readFile(stateFile, 'utf8'), key).env.MARK, 'value');
  assert.equal((await fs.stat(stateFile)).mode & 0o777, 0o600);
});

test('pre failure preserves registered cleanup and literal false does not tolerate composite failure', async t => {
  const { config, runtime } = await fixture(t);
  const uses = await action(config, 'pre-failure', 'runs: {using: node24, pre: pre.cjs, main: main.cjs, post: post.cjs}', {
    'pre.cjs': `require('fs').appendFileSync(process.env.GITHUB_STATE,'saved=pre\\n'); process.exit(3)`,
    'main.cjs': 'process.exit(99)',
    'post.cjs': `require('fs').writeFileSync(process.env.GITHUB_WORKSPACE+'/pre-cleaned',process.env.STATE_saved)`,
  });
  assert.equal((await runtime.action(uses)).code, 3); assert.equal(await runtime.posts(), 0);
  assert.equal(await fs.readFile(path.join(config.workspace, 'pre-cleaned'), 'utf8'), 'pre');
  const composite = await action(config, 'composite-failure', `runs:
  using: composite
  steps:
    - run: exit 3
      shell: sh
      continue-on-error: 'false'
    - if: failure()
      run: echo cleanup > composite-cleaned
      shell: sh`);
  assert.equal((await runtime.action(composite)).code, 1);
  assert.equal(await fs.readFile(path.join(config.workspace, 'composite-cleaned'), 'utf8'), 'cleanup\n');
});

test('error annotations do not change exit status and failed posts affect later post conditions', async t => {
  const { config, runtime } = await fixture(t);
  assert.equal((await runtime.script("printf '::error::annotation only\\n'", 'sh')).code, 0);
  const first = await action(config, 'cleanup-if-failed', 'runs: {using: node24, main: main.cjs, post: post.cjs, post-if: failure()}', {
    'main.cjs':'', 'post.cjs':`require('fs').writeFileSync(process.env.GITHUB_WORKSPACE+'/post-failure-cleanup','yes')`,
  });
  const second = await action(config, 'failing-cleanup', 'runs: {using: node24, main: main.cjs, post: post.cjs}', {'main.cjs':'', 'post.cjs':'process.exit(8)'});
  assert.equal((await runtime.action(first)).code, 0); assert.equal((await runtime.action(second)).code, 0);
  assert.equal(await runtime.posts(), 8);
  assert.equal(await fs.readFile(path.join(config.workspace, 'post-failure-cleanup'), 'utf8'), 'yes');
});

test('dynamic step env resolves before action inputs and input delivery is case insensitive', async t => {
  const { config } = await fixture(t);
  const uses = await action(config, 'env-inputs', `inputs:
  message:
    default: default
runs: {using: node24, main: main.cjs}`, {'main.cjs': `if(process.env.INPUT_MESSAGE!=='ready')process.exit(3)`});
  const state = { steps: {first: {outputs:{value:'ready'}}} };
  const result = await execute({...config, step:{id:'consume', remote:true, uses, env:{}, inputs:{Message:''}, templates:{'with:Message':'${{ env.RESOLVED }}','env:RESOLVED':'${{ steps.first.outputs.value }}'}}}, state);
  assert.equal(result.code, 0);
  const skip = await execute({...config, step:{id:'skip', run:'exit 99', env:{ENABLED:'no'}, templates:{if:"env.ENABLED == 'yes'"}}});
  assert.equal(skip.conclusion, 'skipped');
});

test('ref resolution handles qualified refs and peeled annotated tags without executing a shell', async () => {
  const {resolveCommit} = await import('./download.mjs');
  const sha = 'a'.repeat(40), tag = 'b'.repeat(40);
  for (const ref of ['main', 'refs/heads/main']) {
    const actual = await resolveCommit('owner/action', ref, {}, async (program, args) => {
      assert.equal(program, 'git'); assert.ok(args.includes('refs/heads/main')); assert.ok(!args.includes('refs/heads/refs/heads/main'));
      return {stdout: sha + '\trefs/heads/main\n'};
    });
    assert.equal(actual, sha);
  }
  assert.equal(await resolveCommit('owner/action', 'v1', {}, async () => ({stdout: `${tag}\trefs/tags/v1\n${sha}\trefs/tags/v1^{}\n`})), sha);
});

test('composite scripts receive action paths and per-step environment contexts', async t => {
  const { config, runtime } = await fixture(t);
  const nested = await action(config, 'path-child', [
    'runs:', '  using: composite', '  steps:', '    - shell: bash',
    '      run: test "$GITHUB_ACTION_PATH" = "$GITHUB_WORKSPACE/path-child"; test "${{ github.action_path }}" = "$GITHUB_ACTION_PATH"',
  ].join('\n'));
  const uses = await action(config, 'path-parent', [
    'runs:', '  using: composite', '  steps:', `    - uses: ${nested}`,
    '    - shell: bash', '      env:', '        CHILD_MESSAGE: ready',
    '      run: test "$GITHUB_ACTION_PATH" = "$GITHUB_WORKSPACE/path-parent"; test "${{ env.CHILD_MESSAGE }}" = ready',
  ].join('\n'));
  assert.equal((await runtime.action(uses)).code, 0);
});

test('composite preparation failures retain step status and run conditional cleanup', async t => {
  const { config, runtime } = await fixture(t);
  const uses = await action(config, 'prepare-failure', [
    'runs:', '  using: composite', '  steps:', '    - id: missing',
    '      uses: ./does-not-exist',
    "    - if: failure() && steps.missing.outcome == 'failure'",
    '      shell: sh', '      run: touch composite-preparation-cleanup',
  ].join('\n'));
  assert.equal((await runtime.action(uses)).code, 1);
  assert.equal(await fs.readFile(path.join(config.workspace, 'composite-preparation-cleanup'), 'utf8'), '');
});

test('Actions contexts and functions ignore case while Linux environment keys preserve it', () => {
  const context = { env: { Message: 'ready' }, steps: { build: { outputs: { Result: 'done' } } } };
  assert.equal(evaluate('ENV.Message', context), 'ready');
  assert.equal(evaluate('env.message', context), '');
  assert.equal(evaluate('STEPS.BUILD.OUTPUTS.result', context), 'done');
  assert.equal(evaluate("STARTSWITH('READY', 'read') && SUCCESS()", context), true);
});

test('exported environment overrides inherited env but explicit step env wins', async t => {
  const {config} = await fixture(t);
  const step = (id, run, overrides = []) => ({...config, step:{id, run, shell:'bash', working_directory:'.', env:{VALUE:'initial'}, env_overrides:overrides}});
  const first = await execute(step('export', 'echo VALUE=exported >> "$GITHUB_ENV"'));
  assert.equal(first.code, 0);
  const inherited = await execute(step('inherit', 'test "$VALUE" = exported'), first.state);
  assert.equal(inherited.code, 0);
  const explicit = await execute(step('explicit', 'test "$VALUE" = initial', ['VALUE']), first.state);
  assert.equal(explicit.code, 0);
});

test('top-level preparation failures record outcome for subsequent failure cleanup', async t => {
  const {config} = await fixture(t);
  const result = await execute({...config, step:{id:'bad',run:'exit 99',env:{},templates:{'env:VALUE':"${{ fromJSON('invalid') }}"}}});
  assert.equal(result.code, 1);
  assert.equal(result.state.steps.bad.outcome, 'failure');
  const cleanup = await execute({...config,step:{id:'clean',run:'touch evaluation-cleanup',shell:'sh',working_directory:'.',templates:{if:"failure() && steps.bad.outcome == 'failure'"}}},result.state);
  assert.equal(cleanup.code, 0);
  assert.equal(await fs.readFile(path.join(config.workspace,'evaluation-cleanup'),'utf8'),'');
});

test('typed matrix values reach scripts inputs and conditions without recursive interpolation', async t => {
  const {config}=await fixture(t);
  const matrix={target:'native', enabled:true, literal:'${{ secrets.NEVER }}'};
  const result=await execute({...config,matrix,step:{id:'matrix',run:'test "$TARGET" = native; test "$LITERAL" = \'${{ secrets.NEVER }}\'',shell:'sh',working_directory:'.',templates:{'env:TARGET':'${{ matrix.target }}','env:LITERAL':'${{ matrix.literal }}',if:'matrix.enabled == true'},env:{}}});
  assert.equal(result.code,0);
  assert.equal(result.state.steps.matrix.conclusion,'success');
});

test('Artifact bridge keeps runtime credentials private and canonicalizes upstream output URLs', async t => {
  const { config } = await fixture(t);
  config.run_id = '73';
  const token = 'opaque-artifact-runtime';
  const previous = { token: process.env.MOONHUB_ACTION_ARTIFACT_TOKEN, url: process.env.MOONHUB_ACTION_ARTIFACT_URL };
  process.env.MOONHUB_ACTION_ARTIFACT_TOKEN = token;
  process.env.MOONHUB_ACTION_ARTIFACT_URL = config.server;
  const runtime = new ActionRuntime(config);
  if (previous.token === undefined) delete process.env.MOONHUB_ACTION_ARTIFACT_TOKEN;
  else process.env.MOONHUB_ACTION_ARTIFACT_TOKEN = previous.token;
  if (previous.url === undefined) delete process.env.MOONHUB_ACTION_ARTIFACT_URL;
  else process.env.MOONHUB_ACTION_ARTIFACT_URL = previous.url;
  const uses = await action(config, 'artifact-fixture', 'runs: {using: node20, main: main.cjs}', {
    'main.cjs': `const assert=require('node:assert/strict'),fs=require('node:fs');
      assert.equal(process.env.ACTIONS_RUNTIME_TOKEN,${JSON.stringify(token)});
      assert.equal(process.env.ACTIONS_RESULTS_URL,${JSON.stringify(config.server)});
      assert.equal(process.env.GITHUB_SERVER_URL,'http://moonhub.localhost');
      assert.equal(process.env.MOONHUB_ACTION_ARTIFACT_TOKEN,undefined);
      assert.equal(process.env.MOONHUB_ACTION_ARTIFACT_URL,undefined);
      fs.appendFileSync(process.env.GITHUB_OUTPUT,'artifact-id=42\\nartifact-url=http://moonhub.localhost/fake\\n');`,
  });
  const directory = path.join(config.workspace, uses.slice(2));
  runtime.resolve = async () => ({ directory, repository: 'actions/upload-artifact', ref: 'v4' });
  const result = await runtime.action('actions/upload-artifact@v4');
  assert.equal(result.code, 0);
  assert.equal(result.outputs['artifact-url'], 'https://moonhub.example/alice/demo/actions/runs/73/artifacts/42');
  assert.equal(runtime.context().github.server_url, config.server);
  assert.equal(runtime.baseEnv.MOONHUB_ACTION_ARTIFACT_TOKEN, undefined);
  assert.ok(runtime.state.masks.includes(token));
  await assert.rejects(runtime.action('actions/download-artifact@v4', { 'github-token': 'external-token' }), /Cross-run/);
});

test('Actions file commands cannot replace service credentials', async t => {
  const { config, runtime } = await fixture(t);
  for (const name of ['ACTIONS_RUNTIME_TOKEN', 'ACTIONS_RESULTS_URL', 'ACTIONS_RUNTIME_URL', 'ACTIONS_CACHE_URL', 'ACTIONS_CACHE_SERVICE_V2', 'ACTIONS_CACHE_MODE']) {
    const uses = await action(config, name, 'runs: {using: node24, main: main.cjs}', {
      'main.cjs': `require('fs').appendFileSync(process.env.GITHUB_ENV,${JSON.stringify(name + '=attacker\n')});`,
    });
    await assert.rejects(runtime.action(uses), /Reserved or unsafe/);
  }
});

test('hashFiles hashes content digests, exclusions and lazy expressions within the workspace', async t => {
  const { config } = await fixture(t);
  const { createHash } = await import('node:crypto');
  const sum = (...values) => createHash('sha256').update(Buffer.concat(values.map(v => createHash('sha256').update(v).digest()))).digest('hex');
  const context = { github: { workspace: config.workspace } };
  await fs.mkdir(path.join(config.workspace, 'nested'));
  await fs.writeFile(path.join(config.workspace, 'moon.mod'), 'root');
  await fs.writeFile(path.join(config.workspace, 'nested/moon.mod'), 'nested');
  await fs.writeFile(path.join(config.workspace, '.hidden'), 'hidden');
  assert.equal(await evaluateAsync("hashFiles('**/moon.mod')", context), sum('root', 'nested'));
  assert.equal(await evaluateAsync("hashFiles('**/moon.mod', '!nested/**')", context), sum('root'));
  assert.equal(await evaluateAsync("hashFiles('**/moon.mod', '!nested/**', 'nested/moon.mod')", context), sum('root', 'nested'));
  assert.equal(await evaluateAsync("hashFiles('.hidden')", context), sum('hidden'));
  assert.equal(await evaluateAsync("hashFiles('missing')", context), '');
  assert.equal(await evaluateAsync("false && hashFiles('**')", {}), false);
  assert.equal(await interpolateAsync("cache-${{ hashFiles('moon.mod') }}", context), 'cache-' + sum('root'));
  await fs.writeFile(path.join(config.workspace, 'moon.mod'), 'changed');
  assert.equal(await evaluateAsync("HASHFILES('moon.mod')", context), sum('changed'));
  await fs.writeFile(path.join(config.temp, 'outside'), 'private');
  await fs.symlink(config.temp, path.join(config.workspace, 'outside'));
  await fs.symlink(config.workspace, path.join(config.workspace, 'loop'));
  assert.equal(await evaluateAsync("hashFiles('outside/**', '../tmp/outside')", context), '');
  await assert.rejects(evaluateAsync('hashFiles(42)', context), /string patterns/);
});

test('hashFiles matches toolkit glob semantics and resolves top-level action inputs', async t => {
  const { config } = await fixture(t);
  const { hashFiles } = await import('./hash-files.mjs');
  const { hashFiles: toolkitHash } = await import('@actions/glob');
  const root = await fs.realpath(config.workspace);
  await fs.mkdir(path.join(root, 'folder'));
  for (const [name, value] of Object.entries({ 'folder/moon.mod':'mod', 'folder/a.txt':'a', 'folder/b.txt':'b', '[literal].txt':'brackets', '.hidden':'hidden' })) await fs.writeFile(path.join(root,name),value);
  for (const patterns of [['**/*.txt'],['folder/'],['folder/moon.mod/'],['**', '!folder/**', 'folder/b.txt'],['folder/b.txt', 'folder/a.txt'],['[[]literal].txt']]) {
    const absolute = patterns.map(x => (x.startsWith('!') ? '!' : '') + root + '/' + x.replace(/^!/, '')).join('\n');
    assert.equal(await hashFiles(root, patterns), await toolkitHash(absolute, root));
  }
  const uses = await action(config, 'hash-input', 'inputs: {key: {}}\nruns: {using: node24, main: main.cjs}', {
    'main.cjs': "require('fs').appendFileSync(process.env.GITHUB_OUTPUT,'key='+process.env.INPUT_KEY+'\\n');",
  });
  const state = {};
  const result = await execute({...config, step:{id:'hash',remote:true,uses,env:{},inputs:{key:''},templates:{'with:key':"cache-" + '$' + "{{ hashFiles('folder/moon.mod') }}"}}}, state);
  assert.equal(result.code,0);
  assert.equal(state.steps.hash.outputs.key, 'cache-' + await hashFiles(root,['folder/moon.mod']));
  const alias = path.join(config.temp,'workspace-alias');
  await fs.symlink(root,alias,'dir');
  assert.equal(await hashFiles(alias,[path.join(alias,'folder/moon.mod')]),await hashFiles(root,['folder/moon.mod']));
  const aliasState = {};
  const aliasResult = await execute({...config,workspace:alias,step:{id:'hash',remote:true,uses,env:{},inputs:{key:''},templates:{'with:key':"cache-" + '$' + "{{ hashFiles(format('{0}/folder/moon.mod', github.workspace)) }}"}}},aliasState);
  assert.equal(aliasResult.code,0);
  assert.equal(aliasState.steps.hash.outputs.key,'cache-' + await hashFiles(root,['folder/moon.mod']));
  assert.throws(() => evaluate("hashFiles('**')"), /asynchronous/);
});

test('downloaded subdirectory Actions resolve entry points within their repository including posts', async t => {
  const { config, runtime } = await fixture(t);
  const uses = await action(config, 'subdir', 'runs: {using: node24, main: main.cjs}', {});
  const root = path.join(config.workspace,uses.slice(2));
  await fs.mkdir(path.join(root,'restore'));
  await fs.mkdir(path.join(root,'dist'));
  await fs.writeFile(path.join(root,'restore/action.yml'),'runs: {using: node24, main: ../dist/main.cjs, post: ../dist/post.cjs}');
  await fs.writeFile(path.join(root,'dist/main.cjs'),'');
  await fs.writeFile(path.join(root,'dist/post.cjs'),"require('fs').writeFileSync(process.env.GITHUB_WORKSPACE+'/post-done','done')");
  runtime.resolve = async () => ({root,directory:path.join(root,'restore'),repository:'example/cache',ref:'sha'});
  assert.equal((await runtime.action('example/cache/restore@sha')).code,0);
  assert.equal(await runtime.posts(),0);
  assert.equal(await fs.readFile(path.join(config.workspace,'post-done'),'utf8'),'done');
  await fs.writeFile(path.join(root,'restore/action.yml'),'runs: {using: node24, main: ../../outside.cjs}');
  await assert.rejects(runtime.action('example/cache/restore@sha'),/escapes/);
});

test('job outputs resolve once after post handlers, carry needs and suppress masked values', async t => {
  const { config } = await fixture(t);
  config.needs = { prepare: { result: 'success', outputs: { version: '1.2.3' } } };
  config.job_outputs = {
    version: '${{ steps.build.outputs.version }}',
    forwarded: '${{ needs.prepare.outputs.version }}',
    unsafe: '${{ steps.build.outputs.secret }}',
    literal: '${{ steps.build.outputs.literal }}',
    missing: '${{ steps.absent.outputs.missing }}',
  };
  const local = await action(config, 'local', 'runs: {using: node24, main: main.cjs, post: post.cjs}', {
    'main.cjs': "require('fs').appendFileSync(process.env.GITHUB_OUTPUT,'version=1.2.3\\nsecret=private-value\\nliteral=${{ needs.other.outputs.x }}\\n');",
    'post.cjs': "console.log('::add-mask::private-value'); require('fs').writeFileSync(process.env.GITHUB_WORKSPACE+'/post-finished','yes');",
  });
  const step = { id:'build', remote:true, uses:local, run:'', env:{}, inputs:{}, templates:{'with:unused': '${{ needs.prepare.outputs.version }}'} };
  const executed = await execute({...config, step});
  const result = await execute({...config, phase:'post'}, executed.state);
  assert.equal(result.code, 0);
  assert.deepEqual({...result.outputs}, {version:'1.2.3', forwarded:'1.2.3', literal:'${{ needs.other.outputs.x }}'});
  assert.equal(await fs.readFile(path.join(config.workspace, 'post-finished'), 'utf8'), 'yes');
});
test('job output limits measure UTF-8 and JSON bytes and reject reserved names and NUL', async () => {
  const resolve = value => resolveJobOutputs({value}, {});
  assert.equal((await resolve('x'.repeat(16384))).value.length, 16384);
  for (const value of ['x'.repeat(16385), '密'.repeat(5462), 'a\0b']) await assert.rejects(resolve(value));
  await assert.rejects(resolveJobOutputs({a:'"'.repeat(16384)}, {}));
  await assert.rejects(resolveJobOutputs({constructor:'bad'}, {}));
  await assert.rejects(resolveJobOutputs(Object.fromEntries(Array.from({length:101}, (_,n) => ['k'+n,''])), {}));
  await assert.rejects(resolveJobOutputs({a:'x'.repeat(16380), b:'x'.repeat(16380), c:'x'}, {}));
});

test('workflow dispatch keeps typed inputs and string event inputs through step templates', async t => {
  const { config } = await fixture(t);
  config.dispatch_context = true;
  config.dispatch_inputs = { enabled: true, attempts: 3.5, name: 'nightly', literal: '\${{ inputs.name }}' };
  config.event = { inputs: { enabled: 'true', attempts: '3.5', name: 'nightly', literal: '\${{ inputs.name }}' }, ref: 'refs/heads/main' };
  const make = (id, templates, other = {}) => ({ ...config, step: { id, shell: 'bash', run: '', env: {}, inputs: {}, templates, ...other } });
  let result = await execute(make('typed', {
    if: 'inputs.enabled && inputs.attempts == 3.5',
    'env:ENABLED': '\${{ toJSON(inputs.enabled) }}',
    'env:ATTEMPTS': '\${{ inputs.attempts }}',
    'env:EVENT_ENABLED': '\${{ github.event.inputs.enabled }}',
    'env:EVENT_PATH': '\${{ github.event_path }}',
    run: `test "$ENABLED" = true; test "$ATTEMPTS" = 3.5; test "$EVENT_ENABLED" = true; test "$EVENT_PATH" = "$GITHUB_EVENT_PATH"; test -f "$GITHUB_EVENT_PATH"; echo typed=yes >> "$GITHUB_OUTPUT"`,
  }));
  assert.equal(result.code, 0);
  assert.equal(result.state.steps.typed.outputs.typed, 'yes');
  const uses = await action(config, 'dispatch-consumer', 'inputs: {flag: {}, count: {}, literal: {}}\nruns: {using: node24, main: main.cjs}', {
    'main.cjs': `const fs=require('fs'), assert=require('assert/strict'); assert.equal(process.env.INPUT_FLAG,'true'); assert.equal(process.env.INPUT_COUNT,'3.5'); assert.equal(process.env.INPUT_LITERAL,'\${{ inputs.name }}'); const event=JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH,'utf8')); assert.deepEqual(event.inputs,{enabled:'true',attempts:'3.5',name:'nightly',literal:'\${{ inputs.name }}'}); fs.appendFileSync(process.env.GITHUB_OUTPUT,'received=yes\\n');`,
  });
  result = await execute(make('consumer', {
    'with:flag': '\${{ inputs.enabled }}', 'with:count': '\${{ inputs.attempts }}', 'with:literal': '\${{ inputs.literal }}',
  }, { remote: true, uses }), result.state);
  assert.equal(result.code, 0);
  assert.equal(result.state.steps.consumer.outputs.received, 'yes');
  const runtime = new ActionRuntime(config);
  assert.equal(typeof runtime.context().inputs.enabled, 'boolean');
  assert.equal(typeof runtime.context().inputs.attempts, 'number');
  assert.equal(typeof runtime.context().github.event.inputs.enabled, 'string');
});

test('composite action inputs shadow workflow inputs while event inputs remain isolated', async t => {
  const { config } = await fixture(t);
  config.dispatch_context = true;
  config.dispatch_inputs = { message: 'workflow-value', enabled: false };
  config.event = { inputs: { message: 'workflow-value', enabled: 'false' } };
  const child = await action(config, 'dispatch-child', `inputs: {message: {}}
outputs: {message: {value: '\${{ steps.read.outputs.message }}'}}
runs:
  using: composite
  steps:
    - id: read
      shell: bash
      env:
        MESSAGE: \${{ inputs.message }}
        WORKFLOW_MESSAGE: \${{ github.event.inputs.message }}
      run: test "$MESSAGE" = child-value; test "$WORKFLOW_MESSAGE" = workflow-value; echo "message=$MESSAGE" >> "$GITHUB_OUTPUT"
`);
  const outer = await action(config, 'dispatch-outer', `inputs: {message: {}}
outputs: {message: {value: '\${{ steps.parent.outputs.message }}'}}
runs:
  using: composite
  steps:
    - uses: ${child}
      with: {message: child-value}
    - id: parent
      shell: bash
      env:
        MESSAGE: \${{ inputs.message }}
        WORKFLOW_MESSAGE: \${{ github.event.inputs.message }}
      run: test "$MESSAGE" = action-value; test "$WORKFLOW_MESSAGE" = workflow-value; echo "message=$MESSAGE" >> "$GITHUB_OUTPUT"
`);
  const runtime = new ActionRuntime(config);
  const result = await runtime.action(outer, { message: 'action-value' });
  assert.equal(result.code, 0);
  assert.equal(result.outputs.message, 'action-value');
  assert.deepEqual(runtime.context().inputs, config.dispatch_inputs);
  assert.equal(runtime.context().github.event.inputs.message, 'workflow-value');
});

test('pre/main/post and later steps receive fresh captured event files', async t => {
  const { config } = await fixture(t);
  config.dispatch_context = true;
  config.dispatch_inputs = { enabled: true };
  config.event = { inputs: { enabled: 'true' }, ref: 'refs/heads/main' };
  const verify = `const fs=require('fs'), assert=require('assert/strict'), filename=process.env.GITHUB_EVENT_PATH; assert.ok(filename); const event=JSON.parse(fs.readFileSync(filename,'utf8')); assert.equal(event.inputs.enabled,'true'); assert.equal(event.ref,'refs/heads/main'); fs.appendFileSync(process.env.GITHUB_WORKSPACE+'/event-phases',PHASE+'\\n'); fs.writeFileSync(filename,'{"inputs":{"enabled":"tampered"}}');`;
  const uses = await action(config, 'dispatch-events', 'runs: {using: node24, pre: pre.cjs, main: main.cjs, post: post.cjs}', {
    'pre.cjs': "const PHASE='pre';" + verify,
    'main.cjs': "const PHASE='main';" + verify,
    'post.cjs': "const PHASE='post';" + verify,
  });
  const runtime = new ActionRuntime(config);
  config.event.inputs.enabled = 'modified-after-construction';
  assert.equal((await runtime.action(uses)).code, 0);
  assert.equal(await runtime.posts(), 0);
  assert.equal(runtime.context().github.event.inputs.enabled, 'true');
  assert.equal(await fs.readFile(path.join(config.workspace, 'event-phases'), 'utf8'), 'pre\nmain\npost\n');
  await assert.rejects(fs.stat(runtime.context().github.event_path), { code: 'ENOENT' });
  const later = await execute({ ...config, event: { inputs: { enabled: 'true' }, ref: 'refs/heads/main' }, step: { id: 'later', remote: true, uses, env: {}, inputs: {} } }, runtime.state);
  assert.equal(later.code, 0);
  assert.equal((await execute({ ...config, event: { inputs: { enabled: 'true' }, ref: 'refs/heads/main' }, phase: 'post' }, later.state)).code, 0);
});

test('legacy action runtimes preserve missing dispatch and event contexts', async t => {
  const { config, runtime } = await fixture(t);
  assert.equal(Object.hasOwn(runtime.context(), 'inputs'), false);
  assert.equal(Object.hasOwn(runtime.context().github, 'event'), false);
  assert.equal(Object.hasOwn(runtime.context().github, 'event_path'), false);
  assert.equal(evaluate('!github.event', runtime.context()), true);
  assert.equal(evaluate("github.event.ref == ''", runtime.context()), true);
  assert.equal(evaluate("github.event_path == ''", runtime.context()), true);
  assert.throws(() => evaluate('inputs', runtime.context()));
  assert.throws(() => new ActionRuntime({ ...config, dispatch_inputs: { enabled: true } }));
  assert.throws(() => new ActionRuntime({ ...config, event: { ref: 'refs/heads/main' } }));
  const uses = await action(config, 'legacy-event', 'runs: {using: node24, main: main.cjs}', {
    'main.cjs': `const fs=require('fs'), assert=require('assert/strict'); assert.equal(process.env.GITHUB_EVENT_PATH,undefined); assert.deepEqual(fs.readdirSync(process.env.RUNNER_TEMP).filter(name=>name.startsWith('_event-')),[]); fs.appendFileSync(process.env.GITHUB_OUTPUT,'legacy=yes\\n');`,
  });
  const result = await execute({ ...config, step: { id: 'legacy', remote: true, uses, env: {}, inputs: {}, templates: { if: '!github.event' } } });
  assert.equal(result.code, 0);
  assert.equal(result.state.steps.legacy.outputs.legacy, 'yes');
});

test('dispatch runtime defaults new contexts and rejects malformed or oversized payloads', async t => {
  const { config } = await fixture(t);
  config.dispatch_context = true;
  const runtime = new ActionRuntime(config);
  assert.deepEqual(runtime.context().inputs, {});
  assert.deepEqual(runtime.context().github.event, {});
  const uses = await action(config, 'empty-event', 'runs: {using: node24, main: main.cjs}', {
    'main.cjs': `const fs=require('fs'), assert=require('assert/strict'); assert.deepEqual(JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH,'utf8')),{});`,
  });
  assert.equal((await runtime.action(uses)).code, 0);
  for (const dispatch_inputs of [[], 'bad', { nested: {} }, { nullable: null }, { invalid: NaN }, { invalid: Infinity }, { nul: 'a\0b' }, { constructor: 'bad' }, { Name: 'one', name: 'two' }, { 'bad.name': 'bad' }, Object.fromEntries(Array.from({ length: 26 }, (_, n) => ['x' + n, ''])), { large: '密'.repeat(22000) }]) {
    assert.throws(() => new ActionRuntime({ ...config, dispatch_inputs }));
  }
  for (const event of [[], 'bad', { large: '密'.repeat(66000) }]) assert.throws(() => new ActionRuntime({ ...config, event }));
});
