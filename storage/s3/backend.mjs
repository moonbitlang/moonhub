import {
  S3Client, PutObjectCommand, GetObjectCommand, HeadObjectCommand, DeleteObjectCommand,
  CreateMultipartUploadCommand, UploadPartCommand, CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand, ListMultipartUploadsCommand,
  ListObjectsV2Command, DeleteObjectsCommand,
} from '@aws-sdk/client-s3';
import { createHash } from 'node:crypto';

const partBytes = 8 * 1024 * 1024;
const maximumBytes = 2 * 1024 * 1024 * 1024;
const validSegment = s => typeof s === 'string' && /^[A-Za-z0-9_-]+$/.test(s);

export function createStore(location, { signal, client } = {}) {
  if (location?.type !== 's3' || !/^[a-z0-9.-]{3,63}$/.test(location.bucket ?? '') ||
      !/^[A-Za-z0-9-]{1,64}$/.test(location.region ?? '') ||
      !location.prefix?.split('/').every(validSegment)) throw Error('InvalidConfiguration');
  if (location.endpoint) {
    const endpoint = new URL(location.endpoint);
    if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash ||
        (endpoint.protocol !== 'https:' && !(endpoint.protocol === 'http:' && endpoint.hostname === '127.0.0.1'))) {
      throw Error('InvalidConfiguration');
    }
  }
  client ??= new S3Client({
    region: location.region,
    endpoint: location.endpoint,
    forcePathStyle: location.force_path_style ?? false,
    maxAttempts: 3,
    requestHandler: { connectionTimeout: 5000, requestTimeout: 30000 },
  });
  const Bucket = location.bucket;
  const send = command => client.send(command, { abortSignal: signal });
  const key = value => {
    if (typeof value !== 'string' || value.length > 256 || value.split('/').length !== 2 ||
        !value.split('/').every(validSegment)) throw Error('InvalidKey');
    return `${location.prefix}/${value}`;
  };
  const read = async (value, size) => {
    const response = await send(new GetObjectCommand({ Bucket, Key: key(value) }));
    if (response.ContentLength !== Number(size)) {
      response.Body?.destroy();
      throw Error('IntegrityFailure');
    }
    return response.Body;
  };
  return {
    close: () => client.destroy(),
    async put(value, bytes) {
      if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > 128 * 1024 * 1024) throw Error('IntegrityFailure');
      await send(new PutObjectCommand({ Bucket, Key: key(value), Body: bytes, ContentLength: bytes.length, IfNoneMatch: "*" }));
    },
    read,
    async compose(value, parts) {
      const Key = key(value);
      if (!Array.isArray(parts) || !parts.length || parts.length > 256) throw Error('InvalidKey');
      let expectedTotal = 0;
      for (const part of parts) {
        key(part.key);
        const size = Number(part.size);
        if (part.key.split('/')[0] !== value.split('/')[0] || !Number.isSafeInteger(size) || size < 1 ||
            size > 128 * 1024 * 1024 || !/^[0-9a-f]{64}$/.test(part.digest)) throw Error('IntegrityFailure');
        expectedTotal += size;
      }
      if (expectedTotal > maximumBytes) throw Error('IntegrityFailure');
      // Generation keys are allocated uniquely by Pipeline. This explicit check
      // also protects retries on compatible services that ignore conditional
      // multipart completion; AWS additionally enforces If-None-Match below.
      let exists = true;
      try { await send(new HeadObjectCommand({ Bucket, Key })); }
      catch (error) {
        if (error.$metadata?.httpStatusCode !== 404 && error.name !== 'NotFound') throw error;
        exists = false;
      }
      if (exists) throw Error('PreconditionFailed');
      const { UploadId } = await send(new CreateMultipartUploadCommand({ Bucket, Key }));
      let success = false;
      try {
        const completed = [];
        const fullHash = createHash('sha256');
        let buffer = Buffer.allocUnsafe(partBytes), used = 0, total = 0;
        const upload = async body => {
          const PartNumber = completed.length + 1;
          const response = await send(new UploadPartCommand({ Bucket, Key, UploadId, PartNumber, Body: body, ContentLength: body.length }));
          completed.push({ PartNumber, ETag: response.ETag });
        };
        // Azure block sizes and order need not satisfy S3 multipart boundaries.
        // Repack the ordered stream into bounded 8 MiB parts without a disk spool.
        for (const part of parts) {
          const body = await read(part.key, part.size);
          const hash = createHash('sha256');
          let length = 0;
          try {
            for await (const chunk of body) {
              length += chunk.length;
              if (length > Number(part.size)) throw Error('IntegrityFailure');
              hash.update(chunk); fullHash.update(chunk); total += chunk.length;
              for (let offset = 0; offset < chunk.length;) {
                const copied = Math.min(partBytes - used, chunk.length - offset);
                chunk.copy(buffer, used, offset, offset + copied);
                used += copied; offset += copied;
                if (used === partBytes) {
                  await upload(buffer);
                  buffer = Buffer.allocUnsafe(partBytes); used = 0;
                }
              }
            }
          } finally { body.destroy(); }
          if (length !== Number(part.size) || hash.digest('hex') !== part.digest) throw Error('IntegrityFailure');
        }
        if (used) await upload(buffer.subarray(0, used));
        if (total !== expectedTotal) throw Error('IntegrityFailure');
        await send(new CompleteMultipartUploadCommand({ Bucket, Key, UploadId, IfNoneMatch: '*', MultipartUpload: { Parts: completed } }));
        success = true;
        return { size: String(total), digest: `sha256:${fullHash.digest('hex')}` };
      } finally {
        if (!success) {
          // A durable application deletion intent and the bucket's incomplete
          // upload lifecycle rule cover a crash or an unsuccessful abort.
          await client.send(new AbortMultipartUploadCommand({ Bucket, Key, UploadId })).catch(() => {});
        }
      }
    },
    async remove(value) {
      const Key = key(value);
      let KeyMarker, UploadIdMarker;
      do {
        const page = await send(new ListMultipartUploadsCommand({ Bucket, Prefix: Key, KeyMarker, UploadIdMarker }));
        for (const upload of page.Uploads ?? []) {
          if (upload.Key === Key) await send(new AbortMultipartUploadCommand({ Bucket, Key, UploadId: upload.UploadId }));
        }
        KeyMarker = page.IsTruncated ? page.NextKeyMarker : undefined;
        UploadIdMarker = page.IsTruncated ? page.NextUploadIdMarker : undefined;
      } while (KeyMarker);
      await send(new DeleteObjectCommand({ Bucket, Key }));
    },
    async removeNamespace(value) {
      if (!validSegment(value)) throw Error('InvalidKey');
      const Prefix = `${location.prefix}/${value}/`;
      // Abort uploads as well as deleting objects. Neither operation alone
      // releases all storage after a killed multipart finalization.
      let KeyMarker, UploadIdMarker;
      do {
        const page = await send(new ListMultipartUploadsCommand({ Bucket, Prefix, KeyMarker, UploadIdMarker }));
        for (const upload of page.Uploads ?? []) {
          await send(new AbortMultipartUploadCommand({ Bucket, Key: upload.Key, UploadId: upload.UploadId }));
        }
        KeyMarker = page.IsTruncated ? page.NextKeyMarker : undefined;
        UploadIdMarker = page.IsTruncated ? page.NextUploadIdMarker : undefined;
      } while (KeyMarker);
      for (;;) {
        const page = await send(new ListObjectsV2Command({ Bucket, Prefix, MaxKeys: 1000 }));
        if (!page.Contents?.length) break;
        const command = new DeleteObjectsCommand({ Bucket, Delete: { Objects: page.Contents.map(({ Key }) => ({ Key })), Quiet: true } });
        // Some S3-compatible servers require Content-MD5 for multi-delete even
        // when the SDK also sends a flexible checksum. Hash the SDK's exact XML.
        command.middlewareStack.add(next => async args => {
          args.request.headers['content-md5'] = createHash('md5').update(args.request.body).digest('base64');
          return next(args);
        }, { step: 'build', name: 'multiDeleteMd5' });
        const result = await send(command);
        if (result.Errors?.length) throw Error('DeletionFailure');
      }
    },
  };
}
