import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { createHash } from 'node:crypto';
import { createStore } from './backend.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const location = { type: 's3', bucket: 'moonhub-test', region: 'us-west-2', prefix: 'private/ci' };
function fixture() {
  const objects = new Map(), uploads = new Map(), calls = [];
  let failPart = false, deleteFailure = false;
  const client = {
    destroy() {},
    async send(command) {
      const x = command.input, type = command.constructor.name;
      calls.push({ type, ...x });
      if (type === 'PutObjectCommand') { if (x.IfNoneMatch === '*' && objects.has(x.Key)) throw Error('PreconditionFailed');objects.set(x.Key, Buffer.from(x.Body));return {}; }
      if (type === 'HeadObjectCommand') {
        if (!objects.has(x.Key)) { const error = Error('NotFound');error.name = 'NotFound';throw error; }
        return { ContentLength: objects.get(x.Key).length };
      }
      if (type === 'GetObjectCommand') {
        const bytes = objects.get(x.Key);if (!bytes) throw Error('NoSuchKey');
        return { ContentLength: bytes.length, Body: Readable.from((function* () {
          for (let i = 0; i < bytes.length; i += 65536) yield bytes.subarray(i, i + 65536);
        })()) };
      }
      if (type === 'CreateMultipartUploadCommand') { uploads.set('u', { key: x.Key, parts: new Map() });return { UploadId: 'u' }; }
      if (type === 'UploadPartCommand') {
        if (failPart) throw Error('Injected upload failure');
        uploads.get(x.UploadId).parts.set(x.PartNumber, Buffer.from(x.Body));return { ETag: String(x.PartNumber) };
      }
      if (type === 'CompleteMultipartUploadCommand') {
        if (x.IfNoneMatch === '*' && objects.has(x.Key)) throw Error('PreconditionFailed');
        const upload = uploads.get(x.UploadId);
        const parts = x.MultipartUpload.Parts.map(p => upload.parts.get(p.PartNumber));
        for (const part of parts.slice(0, -1)) assert.ok(part.length >= 5 * 1024 * 1024);
        objects.set(x.Key, Buffer.concat(parts));uploads.delete(x.UploadId);return {};
      }
      if (type === 'AbortMultipartUploadCommand') { uploads.delete(x.UploadId);return {}; }
      if (type === 'DeleteObjectCommand') { objects.delete(x.Key);return {}; }
      if (type === 'ListMultipartUploadsCommand') {
        return { Uploads: [...uploads].filter(([, u]) => u.key.startsWith(x.Prefix)).map(([UploadId, u]) => ({ Key: u.key, UploadId })) };
      }
      if (type === 'ListObjectsV2Command') return { Contents: [...objects.keys()].filter(k => k.startsWith(x.Prefix)).slice(0, x.MaxKeys).map(Key => ({ Key })) };
      if (type === 'DeleteObjectsCommand') {
        if (deleteFailure) return { Errors: [{ Code: 'AccessDenied' }] };
        for (const { Key } of x.Delete.Objects) objects.delete(Key);return {};
      }
      throw Error('Unexpected command ' + type);
    },
  };
  return { store: createStore(location, { client }), objects, uploads, calls,
    failPart: value => { failPart = value; }, failDelete: value => { deleteFailure = value; } };
}

test('repackages arbitrary ordered blocks into valid S3 parts without changing bytes', async () => {
  const f = fixture();
  const inputs = [Buffer.from('end'), Buffer.alloc(9 * 1024 * 1024 + 23, 42), Buffer.from('start')];
  for (let i = 0; i < inputs.length; i++) await f.store.put(`run/block-${i}`, inputs[i]);
  const parts = [2, 1, 0].map(i => ({ key: `run/block-${i}`, size: String(inputs[i].length), digest: hash(inputs[i]) }));
  const expected = Buffer.concat([inputs[2], inputs[1], inputs[0]]);
  const info = await f.store.compose('run/archive-one', parts);
  assert.deepEqual(info, { size: String(expected.length), digest: 'sha256:' + hash(expected) });
  assert.deepEqual(f.objects.get('private/ci/run/archive-one'), expected);
  assert.equal(f.calls.filter(x => x.type === 'UploadPartCommand').length, 2);
  assert.equal(f.uploads.size, 0);
});

test('digest and length mismatch aborts finalization without publishing an object', async () => {
  const f = fixture();await f.store.put('run/block', Buffer.from('data'));
  for (const part of [
    { key: 'run/block', size: '4', digest: '0'.repeat(64) },
    { key: 'run/block', size: '5', digest: hash('data') },
  ]) {
    await assert.rejects(f.store.compose('run/archive-bad', [part]));
    assert.equal(f.uploads.size, 0);
    assert.equal(f.objects.has('private/ci/run/archive-bad'), false);
  }
});

test('failed multipart write aborts and a fresh generation can retry', async () => {
  const f = fixture();await f.store.put('run/block', Buffer.from('data'));
  const parts = [{ key: 'run/block', size: '4', digest: hash('data') }];
  f.failPart(true);await assert.rejects(f.store.compose('run/archive-failed', parts));
  assert.equal(f.uploads.size, 0);
  f.failPart(false);assert.equal((await f.store.compose('run/archive-retry', parts)).digest, 'sha256:' + hash('data'));
});

test('immutable archive collisions preserve the already published object', async () => {
  const f = fixture();
  await f.store.put('run/block', Buffer.from('data'));
  await f.store.put('run/archive', Buffer.from('existing'));
  await assert.rejects(f.store.compose('run/archive', [{ key: 'run/block', size: '4', digest: hash('data') }]));
  assert.deepEqual(f.objects.get('private/ci/run/archive'), Buffer.from('existing'));
  assert.equal(f.uploads.size, 0);
});

test('namespace cleanup aborts multipart uploads and retries partial deletion failures', async () => {
  const f = fixture();await f.store.put('run/block', Buffer.from('data'));
  await f.store.put('another/keep', Buffer.from('keep'));
  f.uploads.set('pending', { key: 'private/ci/run/archive-pending', parts: new Map() });
  f.failDelete(true);await assert.rejects(f.store.removeNamespace('run'));
  assert.equal(f.uploads.size, 0);assert.equal(f.objects.size, 2);
  f.failDelete(false);await f.store.removeNamespace('run');await f.store.removeNamespace('run');
  assert.deepEqual([...f.objects.keys()], ['private/ci/another/keep']);
});

test('object keys cannot escape their configured prefix or combine different namespaces', async () => {
  const f = fixture();
  for (const key of ['../escape', '/absolute', 'run/a/b', 'run/../escape', 'run/a?x']) await assert.rejects(f.store.put(key, Buffer.from('x')));
  await assert.rejects(f.store.compose('run/archive', [{ key: 'other/block', size: '1', digest: hash('x') }]));
  assert.equal(f.calls.length, 0);
  assert.throws(() => createStore({ ...location, endpoint: 'http://example.com' }));
  assert.throws(() => createStore({ ...location, prefix: '../escape' }));
});
