import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validatePayload } from '../deploy/macos/guest.mjs';
const valid = () => ({
  version: 1,
  server: 'https://moonhub.example',
  token: 'a'.repeat(64),
  assignment: { attempt_id: '1', job: { runs_on: ['self-hosted', 'macos', 'arm64'] } },
});
test('guest envelope validates credentials origin and explicit macOS routing', () => {
  assert.equal(validatePayload(valid()).assignment.attempt_id, '1');
  for (const change of [
    { token: 'secret' },
    { server: 'https://user:password@moonhub.example' },
    { server: 'http://moonhub.example' },
    { server: 'https://moonhub.example/path' },
    { version: 2 },
    { assignment: { attempt_id: '1', job: { runs_on: ['self-hosted', 'linux'] } } },
    { assignment: { attempt_id: '1', job: { runs_on: ['macos', 'windows'] } } },
  ])
    assert.throws(() => validatePayload({ ...valid(), ...change }));
  assert.equal(
    validatePayload({ ...valid(), server: 'http://192.168.64.1:8080', allow_http: true })
      .allow_http,
    true,
  );
});
