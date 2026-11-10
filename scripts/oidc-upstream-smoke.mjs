// Opt-in acceptance: unmodified, SHA-pinned configure-aws-credentials v5 uses
// the real MoonHub OIDC endpoint and an isolated, signature-verifying STS stub.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import { createPublicKey, verify } from 'node:crypto';
import { ActionRuntime } from '../runner/actions/runtime.mjs';

const config = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
assert.equal(new URL(config.request_url).origin, config.issuer);
let exchanges = 0, identities = 0;
const server = http.createServer(async (req, res) => {
  try {
    assert.equal(req.method, 'POST');
    const chunks = []; let length = 0;
    for await (const chunk of req) { length += chunk.length; assert.ok(length <= 65536); chunks.push(chunk); }
    const form = new URLSearchParams(Buffer.concat(chunks).toString());
    if (form.get('Action') === 'AssumeRoleWithWebIdentity') {
      assert.equal(form.get('RoleArn'), 'arn:aws:iam::123456789012:role/moonhub-test');
      const jwt = form.get('WebIdentityToken');
      const [h, p, s] = jwt.split('.'), header = JSON.parse(Buffer.from(h, 'base64url'));
      const claims = JSON.parse(Buffer.from(p, 'base64url'));
      assert.equal(header.alg, 'RS256');
      const response = await fetch(config.issuer + '/-/oidc/jwks'); assert.ok(response.ok);
      const { keys } = await response.json(), jwk = keys.find(key => key.kid === header.kid);
      assert.ok(verify('RSA-SHA256', Buffer.from(h + '.' + p), createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(s, 'base64url')));
      assert.equal(claims.iss, config.issuer); assert.equal(claims.aud, 'sts.amazonaws.com');
      assert.equal(claims.repository, 'alice/demo'); assert.equal(claims.sha, config.sha);
      assert.equal(claims.sub, `repo_id:${config.repository_id}:ref:refs/heads/pipeline`);
      assert.ok(claims.exp > Date.now() / 1000 && claims.exp - claims.iat <= 300);
      assert.equal(claims.run_id, config.run_id);
      exchanges++;
      res.writeHead(200, { 'Content-Type': 'text/xml' });
      res.end(`<AssumeRoleWithWebIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><AssumeRoleWithWebIdentityResult><Credentials><AccessKeyId>ASIAMOONHUBTEST000001</AccessKeyId><SecretAccessKey>moonhub-test-secret-not-a-real-aws-key</SecretAccessKey><SessionToken>moonhub-test-session-not-a-real-aws-token</SessionToken><Expiration>${new Date(Date.now() + 3600000).toISOString()}</Expiration></Credentials><AssumedRoleUser><AssumedRoleId>AROAEXAMPLE:test</AssumedRoleId><Arn>arn:aws:sts::123456789012:assumed-role/moonhub-test/test</Arn></AssumedRoleUser><SubjectFromWebIdentityToken>${claims.sub}</SubjectFromWebIdentityToken><Audience>sts.amazonaws.com</Audience><Provider>${config.issuer}</Provider></AssumeRoleWithWebIdentityResult><ResponseMetadata><RequestId>test</RequestId></ResponseMetadata></AssumeRoleWithWebIdentityResponse>`);
    } else if (form.get('Action') === 'GetCallerIdentity') {
      assert.ok(req.headers.authorization?.includes('ASIAMOONHUBTEST000001'));
      identities++;
      res.writeHead(200, { 'Content-Type': 'text/xml' });
      res.end('<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult><Arn>arn:aws:sts::123456789012:assumed-role/moonhub-test/test</Arn><UserId>AROAEXAMPLE:test</UserId><Account>123456789012</Account></GetCallerIdentityResult><ResponseMetadata><RequestId>test</RequestId></ResponseMetadata></GetCallerIdentityResponse>');
    } else throw Error('Unexpected STS operation');
  } catch {
    res.writeHead(403, { 'Content-Type': 'text/xml' });
    res.end('<ErrorResponse><Error><Code>InvalidIdentityToken</Code><Message>OIDC acceptance rejected the request</Message></Error></ErrorResponse>');
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const workspace = path.join(config.root, 'upstream-workspace'), temp = path.join(config.root, 'upstream-tmp');
  await fs.mkdir(workspace); await fs.mkdir(temp);
  process.env.MOONHUB_ACTION_OIDC_TOKEN = config.token;
  process.env.MOONHUB_ACTION_OIDC_URL = config.request_url;
  const runtime = new ActionRuntime({ workspace, temp, repository: 'alice/demo', sha: config.sha,
    server: config.issuer, context: { workflow: 'OIDC acceptance', actor: 'alice' }, run_id: config.run_id, contents_read: false, node24: process.execPath, node20: process.env.MOONHUB_OIDC_NODE20 || process.execPath });
  delete process.env.MOONHUB_ACTION_OIDC_TOKEN; delete process.env.MOONHUB_ACTION_OIDC_URL;
  const result = await runtime.action('aws-actions/configure-aws-credentials@61815dcd50bd041e203e49132bacad1fd04d2708', {
    'role-to-assume': 'arn:aws:iam::123456789012:role/moonhub-test', 'aws-region': 'us-east-1',
    'role-session-name': 'moonhub-oidc-acceptance', 'allowed-account-ids': '123456789012',
    'retry-max-attempts': '1', 'mask-aws-account-id': 'true',
  }, { AWS_ENDPOINT_URL_STS: `http://127.0.0.1:${server.address().port}`, AWS_EC2_METADATA_DISABLED: 'true' });
  assert.equal(result.code, 0); assert.equal(exchanges, 1); assert.ok(identities >= 1);
  assert.equal(runtime.state.env.AWS_ACCESS_KEY_ID, 'ASIAMOONHUBTEST000001');
  assert.equal(runtime.state.env.AWS_SESSION_TOKEN, 'moonhub-test-session-not-a-real-aws-token');
  assert.equal(await runtime.posts(), 0);
  assert.equal(runtime.state.env.AWS_ACCESS_KEY_ID, '');
  assert.equal(runtime.state.env.AWS_SESSION_TOKEN, '');
  console.log('OIDC upstream acceptance passed: signed identity, STS exchange, account check and post cleanup');
} finally {
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
}
