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
assert.equal(graph.version, 2, 'Update this check for the new moon tree schema');

const allowed = {
  '': ['config', 'domain', 'database', 'identity', 'gitops', 'repository', 'ssh', 'web', 'runner', 'pipeline', 'provider', 'pipeline/protocol'],
  domain: [],
  config: [],
  database: ['domain'],
  gitops: ['domain'],
  identity: ['domain', 'database'],
  mail: ['domain', 'database'],
  repository: ['domain', 'config', 'database', 'identity', 'gitops'],
  collaboration: ['domain', 'database', 'identity', 'gitops', 'repository'],
  pipeline: ['domain', 'database', 'identity', 'gitops', 'repository', 'pipeline/workflow', 'pipeline/protocol'],
  'pipeline/protocol': [],
  runner: ['pipeline/protocol'],
  provider: ['pipeline/protocol'],
  'pipeline/workflow': ['vendor/yaml'],
  'vendor/yaml': [],
  ssh: ['domain', 'database', 'gitops', 'repository', 'collaboration'],
  web: [
    'domain', 'database', 'identity', 'repository', 'collaboration', 'mail', 'pipeline',
    'web/assets', 'web/context', 'web/views/auth', 'web/views/account',
    'web/views/namespaces', 'web/views/repositories', 'web/views/issues',
    'web/views/merge_requests', 'web/views/settings', 'web/views/pipelines',
  ],
  'web/assets': ['domain'],
  'web/context': ['domain', 'database', 'gitops', 'identity', 'repository', 'pipeline', 'web/ui'],
  'web/ui': ['domain', 'identity', 'repository', 'collaboration', 'web/assets'],
  'web/views/auth': ['domain', 'database', 'identity', 'web/context', 'web/ui'],
  'web/views/account': ['domain', 'identity', 'ssh', 'web/context', 'web/ui'],
  'web/views/namespaces': ['domain', 'identity', 'repository', 'web/context', 'web/ui'],
  'web/views/repositories': [
    'domain', 'database', 'gitops', 'identity', 'repository', 'web/assets', 'web/context', 'web/ui',
  ],
  'web/views/issues': ['domain', 'identity', 'repository', 'collaboration', 'web/assets', 'web/context', 'web/ui'],
  'web/views/merge_requests': [
    'domain', 'gitops', 'identity', 'repository', 'collaboration', 'web/assets', 'web/context', 'web/ui',
  ],
  'web/views/settings': ['domain', 'mail', 'repository', 'web/assets', 'web/context', 'web/ui'],
  'web/views/pipelines': ['domain', 'pipeline', 'pipeline/protocol', 'web/context'],
  test_support: ['database', 'gitops', 'repository'],
  'web/testkit': [
    'domain', 'database', 'gitops', 'identity', 'repository', 'test_support',
    'web', 'web/context', 'web/views/repositories',
  ],
};
const local = new Set(graph.root);
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
assert.deepEqual(failures, [], failures.join('\n'));
console.log(`Package boundaries verified for ${local.size} packages.`);
