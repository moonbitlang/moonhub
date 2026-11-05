const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const ci = fs.readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');
const deploy = fs.readFileSync(path.join(root, '.github/workflows/deploy.yml'), 'utf8');
const results = ['success', 'failure', 'cancelled', 'skipped'];

test('the actual aggregate gate rejects every non-success combination', () => {
  assert.match(ci, /name: CI required\n    if: \$\{\{ always\(\) \}\}\n    needs: \[self-check, docker-ssh, windows-runner, macos-runner\]/);
  assert.match(ci, /SELF_CHECK_RESULT: \$\{\{ needs.self-check.result \}\}/);
  assert.match(ci, /DOCKER_SSH_RESULT: \$\{\{ needs.docker-ssh.result \}\}/);
  const gate = ci.match(/      - name: Require all checks to succeed[\s\S]*?        run: \|\n((?:          .+\n)+)/)?.[1];
  assert.ok(gate, 'missing aggregate shell gate');
  for (const self of results) for (const docker of results) for (const windows of results) for (const macos of results) {
    const result = spawnSync('bash', ['-e', '-c', gate], {
      env: { ...process.env, SELF_CHECK_RESULT: self, DOCKER_SSH_RESULT: docker, WINDOWS_RUNNER_RESULT: windows, MACOS_RUNNER_RESULT: macos },
      encoding: 'utf8',
    });
    assert.equal(result.status === 0, self === 'success' && docker === 'success' && windows === 'success' && macos === 'success', `${self}/${docker}/${windows}/${macos}`);
  }
});

test('deployment conditions restrict event, repository, branch and completed CI', () => {
  // These expressions use the same boolean operators and string equality in
  // GitHub and JavaScript. Execute the conditions from the workflows themselves.
  const caller = ci.match(/  deploy:\n[\s\S]*?if: >-\n\s+\$\{\{ ([\s\S]*?) \}\}/)?.[1];
  const callee = deploy.match(/if: >-\n\s+\$\{\{ ([\s\S]*?) \}\}/)?.[1];
  assert.ok(caller); assert.ok(callee);
  for (const event of ['pull_request', 'pull_request_target', 'push', 'workflow_dispatch', 'workflow_run']) {
    for (const ref of ['refs/heads/master', 'refs/heads/topic', 'refs/pull/1/merge', 'refs/tags/master']) {
      for (const repository of ['moonbitlang/moonhub', 'other/moonhub']) {
        for (const requested of [false, true]) for (const result of results) {
          const context = { github: { event_name: event, ref, repository }, inputs: { deploy: requested }, needs: { required: { result } } };
          const eligible = repository === 'moonbitlang/moonhub' && ref === 'refs/heads/master' &&
            (event === 'push' || (event === 'workflow_dispatch' && requested));
          assert.equal(vm.runInNewContext(caller, context), eligible && result === 'success');
          assert.equal(vm.runInNewContext(callee, context), eligible);
        }
      }
    }
  }
  assert.match(ci, /    needs: required/);
  assert.match(ci, /    uses: \.\/\.github\/workflows\/deploy.yml/);
  assert.match(deploy, /on:\n  workflow_call:/);
  assert.doesNotMatch(deploy, /^  (push|pull_request|workflow_dispatch):/m);
  assert.doesNotMatch(deploy, /^\s+ref:/m, 'deployment must check out the calling CI commit');
});

test('compiler verification rejects a successful install of the wrong version', () => {
  const verify = ci.match(/      - name: Verify MoonBit version[\s\S]*?node <<'NODE'\n([\s\S]*?)          NODE/)?.[1];
  assert.ok(verify);
  const pin = fs.readFileSync(path.join(root, 'deploy/base.Dockerfile'), 'utf8').match(/^ARG MOONBIT_VERSION=(.+)$/m)[1];
  for (const actual of [`v${pin} (date)\n`, 'v0.0.0+wrong (date)\n', 'stable\n', '']) {
    const run = () => vm.runInNewContext(verify, {
      process: { env: { MOONBIT_VERSION: pin } },
      require: name => name === 'node:child_process' ? { execFileSync: () => actual } : require(name),
    });
    if (actual.startsWith(`v${pin} `)) run();
    else assert.throws(run);
  }
});

test('PR cancellation and production serialization have independent scopes', () => {
  assert.match(ci, /group: ci-\$\{\{ github.event.pull_request.number \|\| github.run_id \}\}/);
  assert.match(ci, /cancel-in-progress: \$\{\{ github.event_name == 'pull_request' \}\}/);
  assert.match(deploy, /group: moonhub-production\n      cancel-in-progress: false/);
  assert.match(deploy, /environment: production/);
});
