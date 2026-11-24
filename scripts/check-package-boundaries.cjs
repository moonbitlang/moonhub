const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const graph = JSON.parse(execFileSync('moon', ['tree', '--package', '--json'], {
  cwd: root,
  encoding: 'utf8',
  maxBuffer: 10 * 1024 * 1024,
}));
assert.equal(graph.status, 'success', JSON.stringify(graph.error));
assert.ok([2, 3].includes(graph.version), 'Update this check for the new moon tree schema');

const allowed = {
  '': ['config', 'domain', 'database', 'identity', 'gitops', 'repository', 'ssh', 'web', 'runner', 'pipeline', 'provider', 'pipeline/protocol', 'cli', 'runner/cli', 'storage', 'pipeline/runtime', 'pipeline/oidc'],
  cli: ['domain', 'diff/protocol'],
  domain: [],
  config: [],
  storage: [],
  filelock: [],
  releases: ["domain", "database", "identity", "repository", "gitops", "storage"],
  database: ['domain'],
  gitops: ['filelock', 'domain', 'diff/protocol'],
  'diff/protocol': [],
  'diff/compute': ['diff/protocol'],
  'cmd/moonhub-diff-worker': ['diff/protocol', 'diff/compute'],
  'cmd/moonhub': ['cli'],
  identity: ['domain', 'database'],
  mail: ['domain', 'database'],
  repository: ['filelock', 'domain', 'config', 'database', 'identity', 'gitops'],
  webhooks: ['domain', 'database', 'identity', 'repository', 'gitops'],
  attachments: ['filelock', 'domain', 'database', 'identity', 'repository'],
  collaboration: ['domain', 'database', 'identity', 'gitops', 'repository', 'attachments'],
  pipeline: ['domain', 'database', 'identity', 'gitops', 'repository', 'collaboration', 'pipeline/workflow', 'pipeline/runtime', 'pipeline/results'],
  'pipeline/runtime': ['domain', 'database', 'identity', 'gitops', 'repository', 'pipeline/workflow', 'pipeline/protocol', 'pipeline/environment'],
  'pipeline/results': ['domain', 'database', 'identity', 'repository', 'storage', 'pipeline/runtime', 'pipeline/protocol'],
  'pipeline/oidc': ['domain', 'database', 'identity', 'pipeline/runtime', 'pipeline/protocol', 'pipeline/workflow'],
  'pipeline/protocol': ['pipeline/environment'],
  'pipeline/environment': [],
  'pipeline/actions': [],
  runner: ['pipeline/protocol', 'pipeline/environment', 'pipeline/actions', 'runner/platform'],
  'runner/cli': ['runner', 'pipeline/protocol', 'runner/platform'],
  'cmd/moonhub-runner': ['provider', 'runner/cli', 'runner/platform', 'pipeline/protocol'],
  provider: ['filelock', 'pipeline/protocol', 'pipeline/environment', 'runner/platform'],
  'runner/platform': [],
  'pipeline/workflow': ['pipeline/actions', 'pipeline/environment'],
  ssh: ['domain', 'database', 'identity', 'gitops', 'repository', 'collaboration'],
  web: [
    'gitops', 'storage', 'releases', 'web/views/releases',
    'domain', 'config', 'database', 'identity', 'repository', 'collaboration', 'mail', 'pipeline', 'pipeline/runtime', 'pipeline/results', 'pipeline/oidc', 'attachments', 'webhooks',
    'web/assets', 'web/api', 'web/mcp', 'web/pipeline_api', 'web/context', 'web/views/auth', 'web/views/account',
    'web/views/namespaces', 'web/views/repositories', 'web/views/issues',
    'web/views/merge_requests', 'web/views/settings', 'web/views/pipelines', 'web/views/notifications', 'web/views/attachments',
  ],
  'web/views/releases': ['releases','domain','repository','web/context','web/ui'],
  'web/api': ['releases', 'webhooks', 'domain', 'database', 'identity', 'repository', 'gitops', 'collaboration', 'pipeline', 'pipeline/runtime', 'attachments', 'web/dto', 'web/context'],
  'web/mcp': ['domain', 'database', 'identity', 'repository', 'gitops', 'collaboration', 'pipeline', 'pipeline/runtime', 'attachments', 'web/dto', 'web/context'],
  'web/dto': ['domain', 'collaboration', 'pipeline/runtime'],
  'web/pipeline_api': ['domain', 'identity', 'pipeline/protocol', 'pipeline/runtime', 'pipeline/results', 'pipeline/oidc', 'web/context'],
  'web/assets': ['domain'],
  'web/context': ['releases', 'diff/protocol', 'webhooks', 'domain', 'database', 'gitops', 'identity', 'repository', 'pipeline/runtime', 'pipeline/results', 'pipeline/oidc', 'web/ui'],
  'web/ui': ['diff/protocol', 'gitops', 'domain', 'identity', 'repository', 'collaboration', 'web/assets', 'web/spa'],
  'web/spa': [],
  'web/client': ['web/spa'],
  'web/views/notifications': ['collaboration', 'domain', 'web/context', 'web/ui'],
  'web/views/attachments': ['attachments', 'domain', 'repository', 'web/context', 'web/ui'],
  'web/views/auth': ['domain', 'database', 'identity', 'web/context', 'web/ui'],
  'web/views/account': ['domain', 'identity', 'ssh', 'web/context', 'web/ui'],
  'web/views/namespaces': ['domain', 'identity', 'repository', 'web/context', 'web/ui'],
  'web/views/repositories': [
    'domain', 'database', 'gitops', 'identity', 'pipeline/runtime', 'repository', 'releases', 'ssh', 'webhooks', 'web/assets', 'web/context', 'web/ui',
  ],
  'web/views/issues': ['domain', 'identity', 'repository', 'collaboration', 'web/assets', 'web/context', 'web/ui'],
  'web/views/merge_requests': [
    'domain', 'gitops', 'identity', 'repository', 'collaboration', 'web/assets', 'web/context', 'web/ui',
  ],
  'web/views/settings': ['domain', 'mail', 'repository', 'web/assets', 'web/context', 'web/ui'],
  'web/views/pipelines': [
    'domain', 'database', 'identity', 'repository', 'pipeline', 'pipeline/runtime', 'pipeline/results', 'pipeline/protocol', 'pipeline/environment',
    'web/assets', 'web/context', 'web/ui',
  ],
  test_support: ['database', 'gitops', 'repository'],
  'web/testkit': [
    'domain', 'database', 'gitops', 'identity', 'repository', 'releases', 'test_support',
    'web', 'web/context', 'web/views/repositories',
  ],
};
const local = new Set(graph.root.filter(id => graph.nodes[id].module === "hackwaly/moonhub"));
const failures = [];
for (const id of local) {
  const name = graph.nodes[id].rel;
  if (!Object.hasOwn(allowed, name)) failures.push(`Unclassified package: ${name}`);
}
for (const edge of graph.edges) {
  if (!local.has(edge.from)) continue;
  const from = graph.nodes[edge.from].rel;
  const target = graph.nodes[edge.to];
  const production = edge.kinds.includes('source');
  if (local.has(edge.to) && production && !allowed[from]?.includes(target.rel)) {
    failures.push(`${from || '(root)'} must not import ${target.rel || '(root)'} in production`);
  }
  if (production && local.has(edge.to) && ['test_support', 'web/testkit'].includes(target.rel) && from !== 'web/testkit') {
    failures.push(`${from || '(root)'} must not import test fixtures in production`);
  }
  if (from === 'filelock' && !['moonbitlang/async', 'moonbitlang/core'].includes(target.module)) {
    failures.push('filelock must depend only on async and core packages, including in tests');
  }
  if (['pipeline/runtime', 'pipeline/results', 'pipeline/oidc'].includes(from) && local.has(edge.to) && target.rel === 'pipeline') {
    failures.push(`${from} must not depend on Pipeline orchestration, including in tests`);
  }
  if (from === 'pipeline/runtime' && local.has(edge.to) && ['pipeline/results', 'pipeline/oidc'].includes(target.rel)) {
    failures.push(`${from} must not depend on Results or OIDC, including in tests`);
  }
  if (from === 'web/dto' && (
    target.module === 'moonbitlang/moonback' ||
    (target.module === 'moonbitlang/async' && /^http(?:\/|$)/.test(target.rel)) ||
    ['moonbitstack/moondb', 'moonbitstack/moonsqlite'].includes(target.module) ||
    (local.has(edge.to) && target.rel === 'database')
  )) {
    failures.push('web/dto must not directly depend on Moonback, HTTP or database packages');
  }
  const fromWeb = from === 'web' || from.startsWith('web/');
  if (target.module === 'moonbitlang/moonback' && !fromWeb) {
    failures.push(`${from || '(root)'} must not depend on the Web framework`);
  }
  if (local.has(edge.to) && (target.rel === 'web' || target.rel.startsWith('web/')) && !fromWeb && from !== '') {
    failures.push(`${from} must not depend on web packages, including in tests`);
  }
  if (from.startsWith('web/views/') && target.rel.startsWith('web/views/') && from !== target.rel) {
    failures.push(`${from} must not depend on sibling page package ${target.rel}`);
  }
}
// Verify the standalone executable's entire production dependency slice.
const runnerEntry = [...local].find(id => graph.nodes[id].rel === 'cmd/moonhub-runner');
const visited = new Set();
const pending = [runnerEntry];
while (pending.length) {
  const id = pending.pop();
  if (visited.has(id)) continue;
  visited.add(id);
  const target = graph.nodes[id];
  if (local.has(id) && (['database', 'pipeline', 'pipeline/runtime', 'pipeline/results', 'pipeline/oidc', 'web'].includes(target.rel) || target.rel.startsWith('web/'))) {
    failures.push(`Standalone runner must not include ${target.rel}`);
  }
  for (const edge of graph.edges) {
    if (edge.from === id && edge.kinds.includes('source')) pending.push(edge.to);
  }
}
assert.deepEqual(failures, [], failures.join('\n'));
console.log(`Package boundaries verified for ${local.size} packages.`);
