// Disposable S3 integration: no production bucket, credentials, ports or volumes.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';
const require = createRequire(new URL('../storage/s3/package.json', import.meta.url));
const { S3Client, CreateBucketCommand, ListObjectsV2Command, ListMultipartUploadsCommand } = require('@aws-sdk/client-s3');
const name = `moonhub-s3-smoke-${randomBytes(5).toString('hex')}`;
const docker = args => execFileSync('docker', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const credentials = { accessKeyId: 'moonhub-test', secretAccessKey: 'moonhub-storage-test-only' };
let started = false, client;
try {
  docker(['run', '--detach', '--rm', '--name', name, '--publish', '127.0.0.1::9000',
    '--env', `MINIO_ROOT_USER=${credentials.accessKeyId}`, '--env', `MINIO_ROOT_PASSWORD=${credentials.secretAccessKey}`,
    'minio/minio:RELEASE.2024-01-05T22-17-24Z', 'server', '/data']);
  started = true;
  const port = docker(['port', name, '9000/tcp']).split(':').at(-1);
  const endpoint = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 30000;
  while (true) {
    try { if ((await fetch(endpoint + '/minio/health/ready', { signal: AbortSignal.timeout(1000) })).ok) break; } catch {}
    if (Date.now() > deadline) throw Error('S3 fixture did not become ready');
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  client = new S3Client({ region: 'us-west-2', endpoint, forcePathStyle: true, credentials });
  await client.send(new CreateBucketCommand({ Bucket: 'moonhub-storage-test' }));
  const config = { artifacts: 'remote', caches: 'remote', backends: {
    remote: { type: 's3', bucket: 'moonhub-storage-test', region: 'us-west-2', prefix: 'acceptance', endpoint, force_path_style: true },
  } };
  const env = { ...process.env, AWS_ACCESS_KEY_ID: credentials.accessKeyId, AWS_SECRET_ACCESS_KEY: credentials.secretAccessKey,
    AWS_SESSION_TOKEN: '', MOONHUB_TEST_S3_CONFIG: JSON.stringify(config), MOONHUB_ARTIFACT_UPSTREAM: '1', MOONHUB_CACHE_UPSTREAM: '1' };
  async function tests(args, expected) {
    const child = spawn('moon', ['test', '--strip', '-j', '1', '--deny-warn', ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { output += chunk;process.stdout.write(chunk); });
    const code = await new Promise((resolve, reject) => { child.once('error', reject);child.once('close', resolve); });
    assert.equal(code, 0, output.slice(-4000));
    assert.match(output, new RegExp(`Total tests: ${expected}, passed: ${expected}, failed: 0`), 'Native test process did not report complete results');
  }
  await tests(['storage'], 5);
  await tests(['pipeline', '--filter', 'S3 live*'], 1);
  await tests(['web/views/pipelines/artifact_api_wbtest.mbt'], 9);
  const objects = await client.send(new ListObjectsV2Command({ Bucket: 'moonhub-storage-test', Prefix: 'acceptance/' }));
  assert.ok(objects.KeyCount > 0, 'upstream Actions did not create any remote objects');
  const uploads = await client.send(new ListMultipartUploadsCommand({ Bucket: 'moonhub-storage-test', Prefix: 'acceptance/' }));
  assert.equal(uploads.Uploads?.length ?? 0, 0, 'completed tests leaked multipart uploads');
  console.log('MOONHUB_STORAGE_S3_SMOKE_OK');
} finally {
  client?.destroy();
  if (started) docker(['stop', '--time', '1', name]);
}
