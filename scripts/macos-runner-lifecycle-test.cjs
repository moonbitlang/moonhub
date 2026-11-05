const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { test } = require('node:test');
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function scenario(failCleanup = false) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-tart-state-')),
      file = path.join(root, 'state.json');
    fs.writeFileSync(file, JSON.stringify({ vms: {}, prepared: 0, executions: 0, deleted: 0 }));
    const adapter = path.join(root, 'tart');
    fs.writeFileSync(
      adapter,
      `#!${process.execPath}
const fs=require('node:fs');const state=JSON.parse(fs.readFileSync(${JSON.stringify(file)}));const args=process.argv.slice(2);const save=()=>fs.writeFileSync(${JSON.stringify(file)},JSON.stringify(state));
if(args[0]==='--version')console.log('2.41.1');
else if(args[0]==='list')console.log(JSON.stringify(Object.keys(state.vms).map(Name=>({Name}))));
else if(args[0]==='get')console.log(JSON.stringify({OS:'darwin',State:state.vms[args[1]]?.running?'running':'stopped',Running:!!state.vms[args[1]]?.running}));
else if(args[0]==='clone'){state.vms[args[2]]={running:false};save();}
else if(args[0]==='set'){}
else if(args[0]==='run'){state.vms[args[1]].running=true;state.vms[args[1]].pid=process.pid;save();setInterval(()=>{},1000);}
else if(args[0]==='stop'){try{process.kill(state.vms[args[1]].pid,'SIGKILL')}catch{} state.vms[args[1]].running=false;save();}
else if(args[0]==='delete'){if(${JSON.stringify(failCleanup)})process.exit(1);delete state.vms[args[1]];state.deleted++;save();}
else if(args[0]==='exec'&&args.at(-1)==='health'){const vm=state.vms[args[1]];if(!vm?.running||vm.used)process.exit(2);state.prepared++;save();console.log(JSON.stringify({version:1,os:'macos',arch:'arm64',clean:true,runtime:1}));}
else if(args[0]==='exec'){let input='';process.stdin.on('data',b=>input+=b);process.stdin.on('end',()=>{const body=JSON.parse(input);if(!/^[a-f0-9]{64}$/.test(body.token))process.exit(2);const name=args[2];state.vms[name].used=true;state.executions++;save();console.log(JSON.stringify({reported:true,conclusion:'success'}));});}
else process.exit(2);
`,
      { mode: 0o700 },
    );
    const state = () => JSON.parse(fs.readFileSync(file));
    const registration = 'a'.repeat(64);
    fs.writeFileSync(path.join(root, 'registration'), registration, { mode: 0o600 });
    let token,
      config,
      schema,
      workerKey,
      applied = '0',
      ready = 0,
      claims = 0,
      drained = false,
      failed = false,
      failure;
    const server = http.createServer(async (req, res) => {
      try {
        let raw = '';
        for await (const b of req) raw += b;
        const body = JSON.parse(raw);
        let reply;
        const route = req.url.split('/').pop();
        if (route === 'register' && req.url.includes('providers')) {
          token = body.provider_token;
          config = body.defaults;
          schema = body.schema;
          reply = {
            version: 1,
            id: '1',
            mode: 'tart',
            paused: false,
            config_revision: '1',
            schema,
            config,
            queued_jobs: 1,
            workers: [],
          };
        } else if (req.url.includes('providers/sync')) {
          applied = body.applied_revision;
          reply = {
            version: 1,
            id: '1',
            mode: 'tart',
            paused: false,
            config_revision: '1',
            schema,
            config,
            queued_jobs: 1,
            workers: ready
              ? [
                  {
                    id: '1',
                    key: workerKey,
                    state: 'ready',
                    draining: false,
                    applied_revision: '1',
                    last_seen_ms: String(Date.now()),
                    idle_since_ms: String(Date.now()),
                    active_attempts: 0,
                  },
                ]
              : [],
          };
        } else if (req.url.includes('workers/register')) {
          workerKey = body.key;
          reply = { version: 1, id: '1' };
        } else if (req.url.includes('workers/sync')) {
          if (body.state === 'ready') {
            const st = state();
            assert.equal(Object.values(st.vms).filter((vm) => vm.running && !vm.used).length, 1);
            assert.equal(st.deleted, st.executions);
            ready++;
          }
          if (body.state === 'failed') { if(failCleanup)failed=true;else throw Error('worker failed'); }
          if (body.state === 'drained') {
            assert.deepEqual(state().vms, {}, 'drained before VM cleanup');
            drained = true;
          }
          reply = {
            version: 1,
            provider_id: '1',
            worker_id: '1',
            paused: false,
            draining: state().executions === 2,
            config_revision: '1',
            config,
          };
        } else if (route === 'claims') {
          assert.equal(body.runner_os, 'macos');
          assert.ok(ready > 0);
          const st = state();
          assert.equal(st.deleted, st.executions);
          if (applied !== '1') reply = { version: 1, assignment: null };
          else {
            claims++;
            const now = Date.now();
            reply = {
              version: 1,
              assignment: {
                version: 1,
                attempt_id: String(claims),
                run_id: '1',
                job_id: '1',
                repository: 'a/b',
                commit_sha: 'a'.repeat(40),
                state: 'leased',
                server_time_ms: String(now),
                lease_until_ms: String(now + 60000),
                job: {
                  id: 'mac',
                  name: 'Mac',
                  runs_on: ['self-hosted', 'macos'],
                  timeout_minutes: 1,
                  steps: [
                    {
                      id: 'check',
                      name: 'Check',
                      run: 'true',
                      shell: 'bash',
                      working_directory: '.',
                      env: {},
                      timeout_minutes: 0,
                    },
                  ],
                },
              },
            };
          }
        } else if (route === 'drain') reply = { version: 1 };
        else throw Error(req.url);
        res.writeHead(200, { 'Content-Type': 'application/json', Connection: 'close' });
        res.end(JSON.stringify(reply));
      } catch (error) {
        failure = error;
        res.writeHead(500);
        res.end('{}');
      }
    });
    let child,
      output = '';
    try {
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      child = spawn(
        path.resolve('_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe'),
        [
          'run',
          '--mode',
          'tart',
          '--name',
          'fixture',
          '--server',
          `http://127.0.0.1:${server.address().port}`,
          '--allow-http',
          '--registration-token-file',
          path.join(root, 'registration'),
          '--state-dir',
          path.join(root, 'controller'),
          '--workspace-root',
          path.join(root, 'workspace'),
          '--tart',
          adapter,
          '--tart-home',
          path.join(root, 'vms'),
          '--runner-image',
          'local:template',
        ],
        { stdio: ['ignore', 'pipe', 'pipe'] },
      );
      child.stdout.on('data', (b) => (output += b));
      child.stderr.on('data', (b) => (output += b));
      let exited = false,
        code;
      const closed = new Promise((resolve, reject) => {
        child.once('error', reject);
        child.once('close', (c) => {
          exited = true;
          code = c;
          resolve();
        });
      });
      for (let i = 0; i < 550 && !exited && !failure && !drained; i++) await delay(100);
      if (failure) throw failure;
      if(failCleanup) {
        assert.ok(exited,output);await closed;assert.notEqual(code,0);assert.equal(failed,true);
        assert.equal(claims,1);assert.equal(state().executions,1);assert.equal(state().deleted,0);assert.equal(drained,false);
      } else {
        assert.ok(drained, output);
        assert.equal(exited, false, output);
        child.kill('SIGINT');
        await closed;
        assert.equal(claims, 2);
        assert.equal(state().executions, 2);
        assert.equal(state().deleted, 3);
        assert.equal(drained, true);
        assert.deepEqual(state().vms, {});
      }
    } finally {
      child?.kill('SIGKILL');
      for (const vm of Object.values(state().vms))
        try {
          process.kill(vm.pid, 'SIGKILL');
        } catch {}
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      fs.rmSync(root, { recursive: true, force: true });
    }
  }

test('macOS worker claims only after guest readiness and replaces each consumed slot', {skip:process.platform !== 'darwin',timeout:60000}, () => scenario());
test('macOS cleanup failure prevents readiness and further claims', {skip:process.platform !== 'darwin',timeout:60000}, () => scenario(true));
