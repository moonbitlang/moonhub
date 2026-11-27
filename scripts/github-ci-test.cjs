const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const ci = fs.readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');
const deploy = fs.readFileSync(path.join(root, '.github/workflows/deploy.yml'), 'utf8');
const development = fs.readFileSync(path.join(root, '.github/workflows/development.yml'), 'utf8');
const production = fs.readFileSync(path.join(root, '.github/workflows/production-deploy.yml'), 'utf8');
const results = ['success', 'failure', 'cancelled', 'skipped'];

test('the actual aggregate gate rejects every non-success combination', () => {
  const jobs = ['self-check', 'docker-ssh', 'windows-runner', 'macos-runner', 'frontend', 'build-deploy-regressions'];
  const variables = ['SELF_CHECK_RESULT', 'DOCKER_SSH_RESULT', 'WINDOWS_RUNNER_RESULT', 'MACOS_RUNNER_RESULT', 'FRONTEND_RESULT', 'BUILD_DEPLOY_RESULT'];
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

test('only production pushes or manual retries can deploy after release verification', () => {
  const eligibility = deploy.match(/if: >-\n\s+\${\{ ([\s\S]*?) \}\}/)?.[1];
  assert.ok(eligibility);
  for (const event of ['pull_request', 'push', 'workflow_dispatch', 'workflow_run']) {
    for (const ref of ['refs/heads/master', 'refs/heads/development', 'refs/heads/production', 'refs/tags/production']) {
      for (const repository of ['moonbitlang/moonhub', 'other/moonhub']) {
        const eligible = repository === 'moonbitlang/moonhub' && ref === 'refs/heads/production' &&
          (event === 'push' || event === 'workflow_dispatch');
        assert.equal(vm.runInNewContext(eligibility, { github: { event_name: event, ref, repository } }), eligible);
      }
    }
  }
  assert.match(production, /on:\n  push:\n    branches: \[production\]\n  workflow_dispatch:/);
  assert.match(production, /  deploy:\n    needs: verify/);
  assert.match(production, /    uses: \.\/\.github\/workflows\/deploy.yml/);
  assert.match(ci, /on:\n  push:\n    branches: \['codex\/release\/\*\*'\]/);
  assert.match(ci, /Require a commit from development[\s\S]*compare\/\$GITHUB_SHA\.\.\.development/);
  assert.doesNotMatch(ci, /id-token: write|uses: .*deploy\.yml/);
  assert.match(deploy, /on:\n  workflow_call:/);
  assert.doesNotMatch(deploy, /^  (push|pull_request|workflow_dispatch):/m);
  assert.doesNotMatch(deploy, /^\s+ref:/m, 'deployment must check out the production push commit');
});

test('production verifies the exact SHA through successful CI runs and a successful gate job', () => {
  const script = production.match(/      - name: Require successful release CI for this SHA[\s\S]*?        run: \|\n((?:          .+\n)+)/)?.[1];
  assert.ok(script);
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-release-ci-'));
  try {
    fs.writeFileSync(path.join(fixture, 'gh'), `#!/bin/sh
case "$*" in
  *actions/workflows/ci.yml/runs*)
    case "$*" in
      *"head_sha=$GITHUB_SHA"*"event=push"*"status=success"*'startswith("codex/release/")'*)
        [ "$PROBE" != api-error ] || exit 1
        [ "$PROBE" = empty ] || echo 123
        ;;
      *) exit 1 ;;
    esac
    ;;
  *actions/runs/123/jobs*'name == "CI required" and .conclusion == "success"'*)
    [ "$PROBE" != success ] || echo "CI required"
    ;;
  *) exit 1 ;;
esac
`, { mode: 0o755 });
    for (const probe of ['success', 'empty', 'failed-job', 'api-error']) {
      const { status } = spawnSync('bash', ['-c', script], {
        env: {
          ...process.env, PATH: fixture + ':' + process.env.PATH, PROBE: probe,
          GITHUB_REPOSITORY: 'moonbitlang/moonhub', GITHUB_SHA: 'a'.repeat(40),
        },
      });
      assert.equal(status === 0, probe === 'success', probe);
    }
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true });
  }
});

test('CI pin readers accept archived prereleases and reject unpinned versions', () => {
  const workflows = [ci, fs.readFileSync(path.join(root, '.github/workflows/frontend-checks.yml'), 'utf8')];
  const readers = workflows.map(workflow => {
    const read = workflow.match(/      - name: Read production MoonBit version[\s\S]*?node <<'NODE'\n([\s\S]*?)          NODE/)?.[1];
    assert.ok(read);
    return read;
  });
  const windows = fs.readFileSync(path.join(root, 'scripts/windows-moonbit-runtime-smoke.cjs'), 'utf8');
  const windowsRead = windows.match(/const version = [\s\S]*?(?=const name =)/)?.[0];
  assert.ok(windowsRead);
  for (const pin of ['0.10.21+06da1ed44', '0.10.21+06da1ed44-nightly', '1.0.0-rc1+3c0520448', '1.0.0-rc.1+testpin']) {
    const dockerfile = `ARG MOONBIT_VERSION=${pin}\n`;
    for (const read of readers) {
      let written;
      vm.runInNewContext(read, {
        process: { env: { GITHUB_ENV: 'env-file' } },
        require: name => name === 'node:fs' ? {
          readFileSync: () => dockerfile,
          appendFileSync: (file, value) => { assert.equal(file, 'env-file'); written = value; },
        } : require(name),
      });
      assert.equal(written, `MOONBIT_VERSION=${pin}\n`);
    }
    assert.equal(vm.runInNewContext(windowsRead + '\nversion', {
      fs: { readFileSync: () => dockerfile }, assert,
    }), pin);
  }
  for (const pin of ['latest', 'nightly', '1.0.0-rc1', '1.0.0-rc1+']) {
    for (const read of readers) {
      assert.throws(() => vm.runInNewContext(read, {
        require: name => name === 'node:fs' ? { readFileSync: () => `ARG MOONBIT_VERSION=${pin}\n` } : require(name),
      }), /Expected one exact production MoonBit pin/);
    }
    assert.throws(() => vm.runInNewContext(windowsRead, {
      fs: { readFileSync: () => `ARG MOONBIT_VERSION=${pin}\n` }, assert,
    }), /Missing production MoonBit pin/);
  }
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

test('development PR cancellation and production serialization have independent scopes', () => {
  assert.match(development, /pull_request:\n    branches: \[development\]/);
  assert.match(development, /name: Development required/);
  assert.match(development, /group: development-ci-\$\{\{ github.event.pull_request.number \}\}\n  cancel-in-progress: true/);
  assert.doesNotMatch(development, /^    paths/mi, 'required development check must always run');
  assert.doesNotMatch(development, /id-token: write|uses: .*deploy\.yml/);
  assert.match(deploy, /group: moonhub-production\n      cancel-in-progress: false/);
  assert.match(deploy, /environment: production/);
});

// Application acceptance belongs to its own repository, not the product gate.
test('required MoonHub CI does not execute openseek application workflows', () => {
  assert.doesNotMatch(ci, /openseek|MOONHUB_DESKTOP_WINDOWS_SMOKE|desktop_windows_wbtest|Dockerfile[.]build/);
  assert.match(ci, /node scripts[\/]windows-runner-smoke[.]cjs/);
  assert.match(ci, /scripts[\/]acceptance-http-proxy-test[.]mjs/);
  assert.match(ci, /scripts[\/]run-native-test-test[.]cjs/);
});
