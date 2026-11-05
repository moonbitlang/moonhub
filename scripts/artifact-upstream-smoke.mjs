// Runs the unmodified upstream v4 entry points against a live MoonHub service.
// Invoked by the opt-in native HTTP test with a private, short-lived config file.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { ActionRuntime } from '../runner/actions/runtime.mjs';

const config = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
process.env.MOONHUB_ACTION_ARTIFACT_TOKEN = config.token;
process.env.MOONHUB_ACTION_ARTIFACT_URL = config.server;
const runtime = new ActionRuntime({ ...config, node20: process.env.MOONHUB_ARTIFACT_NODE20 || process.execPath });
const upload = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'; // v4.6.2
const download = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'; // v4.3.0
const large = Buffer.alloc(9 * 1024 * 1024, 0x5a); // Exceeds one Azure SDK block.
async function run(uses, inputs) {
  const result = await runtime.action(uses, inputs);
  assert.equal(result.code, 0, `Upstream ${uses} failed`);
  return result.outputs;
}
if (config.phase === 'produce') {
  const directory = path.join(config.workspace, 'payload');
  await fs.mkdir(directory);
  await fs.writeFile(path.join(directory, 'large.bin'), large);
  await fs.writeFile(path.join(directory, '.hidden'), 'hidden-data');
  const inputs = { name: 'bin-linux', path: directory, 'compression-level': '0', 'retention-days': '1', 'include-hidden-files': 'true', 'if-no-files-found': 'error' };
  const first = await run(upload, inputs);
  await fs.writeFile(path.join(directory, 'overwritten.txt'), 'replacement');
  const replacement = await run(upload, { ...inputs, overwrite: 'true' });
  assert.notEqual(first['artifact-id'], replacement['artifact-id']);
  assert.match(replacement['artifact-digest'], /^[0-9a-f]{64}$/);
  assert.equal(replacement['artifact-url'], `${config.server}/${config.repository}/actions/runs/${config.run_id}/artifacts/${replacement['artifact-id']}`);
  await fs.writeFile(path.join(config.workspace, 'mac.txt'), 'mac-data');
  await run(upload, { name: 'bin-macos', path: 'mac.txt', 'retention-days': '7' });
  const missing = await run(upload, { name: 'must-not-exist', path: 'missing-file', 'if-no-files-found': 'ignore' });
  assert.equal(missing['artifact-id'], undefined);
} else {
  const output = path.join(config.workspace, 'merged');
  await run(download, { pattern: 'bin-*', path: output, 'merge-multiple': 'true' });
  assert.equal(createHash('sha256').update(await fs.readFile(path.join(output, 'large.bin'))).digest('hex'), createHash('sha256').update(large).digest('hex'));
  assert.equal(await fs.readFile(path.join(output, '.hidden'), 'utf8'), 'hidden-data');
  assert.equal(await fs.readFile(path.join(output, 'overwritten.txt'), 'utf8'), 'replacement');
  assert.equal(await fs.readFile(path.join(output, 'mac.txt'), 'utf8'), 'mac-data');
  const response = await fetch(`${config.server}/twirp/github.actions.results.api.v1.ArtifactService/ListArtifacts`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ workflow_run_backend_id: config.run_id, workflow_job_run_backend_id: config.attempt_id }),
  });
  assert.equal(response.status, 200);
  const listed = await response.json();
  const artifact = listed.artifacts.find(item => item.name === 'bin-linux');
  assert.ok(artifact);
  await run(download, { 'artifact-ids': artifact.database_id, path: path.join(config.workspace, 'by-id') });
  assert.equal(await fs.readFile(path.join(config.workspace, 'by-id/bin-linux/overwritten.txt'), 'utf8'), 'replacement');
  await run(download, { name: 'bin-linux', path: path.join(config.workspace, 'by-name') });
  assert.equal(await fs.readFile(path.join(config.workspace, 'by-name/overwritten.txt'), 'utf8'), 'replacement');
}
assert.equal(await runtime.posts(), 0);
console.log(`Artifact v4 upstream ${config.phase} acceptance passed`);
