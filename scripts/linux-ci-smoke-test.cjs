const assert = require('node:assert/strict');
const {test} = require('node:test');
const {createRunnerFixture} = require('./linux-ci-smoke.cjs');

for (const cancel of [false, true]) {
  test(`Linux CI fixture keeps valid leases across clock ticks (${cancel ? 'cancellation' : 'execution'})`, async t => {
    const token = 'a'.repeat(64);
    // Every read crosses a millisecond boundary, making the old two-read bug deterministic.
    let time = 1700000000000;
    const fixture = createRunnerFixture({token, cancel, now: () => time++});
    const {server} = fixture;
    t.after(async () => {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    });
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    let deadline;
    const execution = 'b'.repeat(32);
    async function post(operation, body = {}) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/-/runner-api/v1/attempts/1/${operation}`, {
        method: 'POST',
        headers: {Authorization: 'Bearer ' + token, 'Content-Type': 'application/json'},
        body: JSON.stringify({version: 1, ...body}),
      });
      if (fixture.failure) throw fixture.failure;
      assert.equal(response.status, 200);
      const state = await response.json();
      const now = BigInt(state.server_time_ms);
      assert.equal(BigInt(state.lease_until_ms) - now, 60000n, `${operation}: invalid lease`);
      if (deadline === undefined) {
        deadline = BigInt(state.deadline_ms);
        assert.equal(deadline - now, 300000n);
      }
      assert.equal(BigInt(state.deadline_ms), deadline, 'heartbeats must not extend the job deadline');
      assert.equal(state.execution_id, execution);
      assert.equal(state.attempt_id, '1');
      assert.deepEqual(fixture.events.at(-1).response, state, 'failure diagnostics retain the actual lease response');
      return state;
    }
    const start = await post('start', {execution_id: execution});
    assert.equal(start.state, 'running');
    assert.equal(start.cancel_requested, false);
    await post('steps', {step_id: 'probe', state: 'running'});
    const firstLog = await post('logs', {sequence: '1', text: 'building image\n'});
    assert.equal(firstLog.log_sequence, '1');
    assert.equal(firstLog.cancel_requested, false);
    assert.equal((await post('heartbeat')).cancel_requested, false);
    const ready = await post('logs', {sequence: '2', text: 'CI_DOCKER_READY\n'});
    assert.equal(ready.log_sequence, '2');
    assert.equal(ready.cancel_requested, cancel);
    const heartbeat = await post('heartbeat');
    assert.equal(heartbeat.cancel_requested, cancel);
    assert.equal(heartbeat.log_sequence, '2');
    assert.ok(BigInt(heartbeat.server_time_ms) > BigInt(start.server_time_ms));
    const conclusion = cancel ? 'cancelled' : 'success';
    await post('steps', {step_id: 'probe', state: conclusion});
    const complete = await post('complete', {conclusion, last_log_sequence: '2'});
    assert.equal(complete.state, 'completed');
    assert.equal(complete.conclusion, conclusion);
    assert.equal(fixture.conclusion, conclusion);
    assert.deepEqual(fixture.logs, ['building image\n', 'CI_DOCKER_READY\n']);
  });
}
