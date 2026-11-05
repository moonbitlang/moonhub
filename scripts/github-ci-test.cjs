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
  const jobs = ['self-check', 'docker-ssh', 'windows-runner', 'frontend', 'build-deploy-regressions'];
  const variables = ['SELF_CHECK_RESULT', 'DOCKER_SSH_RESULT', 'WINDOWS_RUNNER_RESULT', 'FRONTEND_RESULT', 'BUILD_DEPLOY_RESULT'];
  const dependencies = ci.match(/name: CI required\n    if: \$\{\{ always\(\) \}\}\n    needs: \[([^\]]+)\]/)?.[1];
  assert.deepEqual(dependencies?.split(', '), jobs);
  for (const [index, job] of jobs.entries()) {
    assert.ok(ci.includes(`${variables[index]}: \${{ needs.${job}.result }}`), `missing result for ${job}`);
  }
  const gate = ci.match(/      - name: Require all checks to succeed[\s\S]*?        run: \|\n((?:          .+\n)+)/)?.[1];
  assert.ok(gate, 'missing aggregate shell gate');
  const combinations = jobs.reduce(values => values.flatMap(value => results.map(result => [...value, result])), [[]]);
  for (const combination of combinations) {
    const result = spawnSync('bash', ['-e', '-c', gate], {
      env: { ...process.env, ...Object.fromEntries(variables.map((variable, index) => [variable, combination[index]])) },
      encoding: 'utf8',
    });
    assert.equal(result.status === 0, combination.every(value => value === 'success'), combination.join('/'));
  }
});

test('additional checks run alongside the standard jobs on the calling commit', () => {
  for (const job of ['frontend', 'build-deploy-regressions']) {
    const caller = ci.match(new RegExp(`^  ${job}:\\n([\\s\\S]*?)(?=^  [a-z-]+:)`, 'm'))?.[1];
    assert.ok(caller, `missing ${job} job`);
    assert.doesNotMatch(caller, /\b(needs|if|continue-on-error|ref):/, `${job} must run independently on the calling commit and block on failures`);
  }
  assert.match(ci, /uses: \.\/\.github\/workflows\/frontend-checks.yml/);
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/frontend-checks.yml'), 'utf8');
  assert.match(workflow, /on:\n  workflow_call:/);
  assert.doesNotMatch(workflow, /^  (push|pull_request|workflow_dispatch):/m);
  assert.doesNotMatch(workflow, /^\s+(ref|continue-on-error):/m);
  assert.doesNotMatch(workflow, /secrets: inherit|id-token: write/);
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
  const pin = fs.readFileSync(path.join(root, 'deploy/base.Dockerfile'), 'utf8').match(/^ARG MOONBIT_VERSION=(.+)$/m)[1];
  for (const workflow of [ci, fs.readFileSync(path.join(root, '.github/workflows/frontend-checks.yml'), 'utf8')]) {
    const verify = workflow.match(/      - name: Verify MoonBit version[\s\S]*?node <<'NODE'\n([\s\S]*?)          NODE/)?.[1];
    assert.ok(verify);
    for (const actual of [`v${pin} (date)\n`, 'v0.0.0+wrong (date)\n', 'stable\n', '']) {
      const run = () => vm.runInNewContext(verify, {
        process: { env: { MOONBIT_VERSION: pin } },
        require: name => name === 'node:child_process' ? { execFileSync: () => actual } : require(name),
      });
      if (actual.startsWith(`v${pin} `)) run();
      else assert.throws(run);
    }
  }
});

test('PR cancellation and production serialization have independent scopes', () => {
  assert.match(ci, /group: ci-\$\{\{ github.event.pull_request.number \|\| github.run_id \}\}/);
  assert.match(ci, /cancel-in-progress: \$\{\{ github.event_name == 'pull_request' \}\}/);
  assert.match(deploy, /group: moonhub-production\n      cancel-in-progress: false/);
  assert.match(deploy, /environment: production/);
});
