import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {test} from 'node:test';
import {forwardAcceptanceRequest} from './acceptance-http-proxy.mjs';

async function serve(server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return new URL('http://127.0.0.1:' + server.address().port);
}
async function close(server) {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}

test('acceptance proxy streams uploads and responses and preserves backend failures', async () => {
  const errors = [];
  const backend = http.createServer(async (req, res) => {
    if (req.url === '/reset') {req.socket.destroy(); return;}
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    res.writeHead(201, {'Content-Type':'application/octet-stream'});
    res.end(Buffer.concat(chunks));
  });
  const origin = await serve(backend);
  const proxy = http.createServer((req, res) => forwardAcceptanceRequest(req, res, origin, {onError:error => errors.push(error)}));
  const url = await serve(proxy);
  try {
    const bytes = Buffer.alloc(1024 * 1024 + 1, 0x61);
    const response = await fetch(url, {method:'PUT', body:bytes});
    assert.equal(response.status, 201);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
    await assert.rejects(fetch(new URL('/reset', url)));
    assert.equal(errors.length, 1);
    assert.equal(errors[0].code, 'ECONNRESET');
  } finally {await close(proxy); await close(backend);}
});

test('cancelling a pending heartbeat closes its upstream request without failing acceptance', async () => {
  const errors = [];
  let received, disconnected;
  const arrived = new Promise(resolve => {received = resolve;});
  const closed = new Promise(resolve => {disconnected = resolve;});
  const backend = http.createServer((req, res) => {
    req.resume();
    res.on('close', disconnected);
    received();
  });
  const origin = await serve(backend);
  const proxy = http.createServer((req, res) => forwardAcceptanceRequest(req, res, origin, {onError:error => errors.push(error)}));
  const url = await serve(proxy);
  const request = http.request(url, {method:'POST'});
  request.on('error', () => {});
  request.end('heartbeat');
  try {
    await arrived;
    request.destroy();
    await closed;
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(errors, []);
  } finally {request.destroy(); await close(proxy); await close(backend);}
});
