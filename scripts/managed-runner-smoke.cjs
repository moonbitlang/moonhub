const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const binary = path.resolve('_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe');
const delay = ms => new Promise(r => setTimeout(r, ms));
const registration = 'a'.repeat(64);

async function scenario(mode, failCleanup = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-managed-'));
  for (const directory of ['controller', 'workspace']) {
    fs.mkdirSync(path.join(root, directory), {mode:0o700});
    fs.writeFileSync(path.join(root, directory, '.existing'), 'preserved', {mode:0o600});
  }
  const stateFile = path.join(root, 'state.json');
  fs.writeFileSync(stateFile, JSON.stringify({calls: [], volumes: [], groups: {on: {desired:0, instances:[]}, spot: {desired:0, instances:[]}}}));
  const state = () => JSON.parse(fs.readFileSync(stateFile));
  const tokenFile = path.join(root, 'registration');
  fs.writeFileSync(tokenFile, registration, {mode:0o600});
  const adapter = path.join(root, 'adapter');
  fs.writeFileSync(adapter, `#!${process.execPath}
const fs = require('node:fs'), assert = require('node:assert/strict');
const file = ${JSON.stringify(stateFile)}, args = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(file));
state.calls.push(args);
const save = () => { fs.writeFileSync(file + '.tmp', JSON.stringify(state)); fs.renameSync(file + '.tmp', file); };
let result = null;
if (args[0] === 'ec2') {
  if (args[1] === 'describe-instance-types') result = [{cpus:2,memory_mib:8192,architectures:['x86_64']}];
  else if (args[1] === 'describe-launch-template-versions') result = [{image:'ami-test',tokens:'required',hop:1}];
  else if (args[1] === 'describe-images') result = ['x86_64'];
  else throw Error('unexpected EC2 command');
} else if (args[0] === 'autoscaling') {
  const name = args[args.indexOf('--auto-scaling-group-name') + 1];
  if (args[1] === 'describe-auto-scaling-groups') {
    const key = args[args.indexOf('--auto-scaling-group-names') + 1];
    result = [{name:key,min:0,max:3,...state.groups[key]}];
  } else if (args[1] === 'set-desired-capacity') {
    const g = state.groups[name];
    g.desired = Number(args[args.indexOf('--desired-capacity') + 1]);
    if (name === 'on' && g.desired > g.instances.length) g.instances.push({id:'i-test',lifecycle:'InService',scale_in_protected:true,instance_type:'m6a.large',template_version:'1'});
  } else if (args[1] === 'update-auto-scaling-group') {
    const request = JSON.parse(fs.readFileSync(args[args.indexOf('--cli-input-json') + 1].slice(7)));
    assert.equal(request.NewInstancesProtectedFromScaleIn, true);
    assert.equal(request.MixedInstancesPolicy.LaunchTemplate.Overrides[0].InstanceType, 'm6a.large');
  } else if (args[1] === 'terminate-instance-in-auto-scaling-group') {
    assert.ok(args.includes('--should-decrement-desired-capacity'));
    for (const g of Object.values(state.groups)) {
      if (g.instances.some(i => i.id === 'i-test')) {g.instances = []; g.desired--;}
    }
  } else if (args[1] !== 'set-instance-protection') throw Error('unexpected ASG command');
} else if (args[0] === 'ssm') {
  if (args[1] === 'put-parameter' || args[1] === 'send-command') {
    const request = JSON.parse(fs.readFileSync(args[args.indexOf('--cli-input-json') + 1].slice(7)));
    if (args[1] === 'put-parameter') {assert.equal(request.Type,'SecureString'); state.bootstrap = JSON.parse(request.Value);}
    else {assert.ok(!request.Parameters.commands.join('').includes(state.bootstrap.token)); state.booted = true;}
  }
} else if (args[0] === 'volume') {
  if (args[1] === 'ls') result = state.volumes.join(String.fromCharCode(10));
  else if (args[1] === 'create') {state.volumes.push(args.at(-1)); result = args.at(-1);}
  else if (args[1] === 'rm') {
    if (${JSON.stringify(failCleanup)}) {save(); process.exit(1);}
    state.volumes = state.volumes.filter(v => v !== args.at(-1));
  } else throw Error('unexpected volume operation');
} else if (args[0] === 'run') {
  assert.ok(args.includes('--read-only')); assert.ok(args.includes('--cap-drop'));
  const manifestMount = args.find(arg => arg.startsWith('type=bind,src='));
  const manifestPath = manifestMount.slice('type=bind,src='.length).split(',dst=')[0];
  assert.equal(fs.statSync(manifestPath).mode & 0o777, 0o444, 'non-root task cannot read a root-owned manifest');
  assert.equal(fs.statSync(require('node:path').dirname(manifestPath)).mode & 0o777, 0o700, 'host assignment directory must remain private');
  process.stdin.resume(); state.containerArgs = args; state.runs = (state.runs || 0) + 1;
  result = JSON.stringify({reported:true,conclusion:'success'});
} else if (args[0] === 'ps') result = '';
else if (!['info','image','rm'].includes(args[0])) throw Error('unexpected adapter operation');
save();
if (result !== null) console.log(typeof result === 'string' ? result : JSON.stringify(result));
`, {mode:0o700});
  const workers = [];
  let providerToken, config, schema, revision = '1', observed = '0', applied = '0', claims = 0, queued = mode === 'asg' ? 0 : 1, paused = false, failure;
  let readyFailures = 0, recoverReadyAt = 0;
  const server = http.createServer(async (req, res) => {
    try {
      let text = ''; for await (const chunk of req) text += chunk;
      const body = JSON.parse(text), route = req.url.replace('/-/runner-api/v1', '');
      let result;
      const snapshot = () => ({version:1,id:'1',mode,paused,config_revision:revision,schema,config,queued_jobs:queued,workers});
      if (route === '/providers/register') {
        assert.equal(req.headers.authorization, 'Bearer ' + registration);
        providerToken = body.provider_token; schema = body.schema; config = {...body.defaults};
        if (mode === 'asg') {config.purchase_policy = 'spot-with-on-demand-fallback'; config.spot_wait_seconds = '30'; config.idle_seconds = '30'; config.standby_workers = '1';}
        result = snapshot();
      } else if (route === '/providers/sync') {
        assert.equal(req.headers.authorization, 'Bearer ' + providerToken);
        observed = body.observed_revision; applied = body.applied_revision;
        if (mode === 'asg' && state().booted) queued = 0;
        result = snapshot();
      } else if (route === '/workers/register') {
        assert.equal(req.headers.authorization, 'Bearer ' + providerToken);
        assert.notEqual(body.token, providerToken);
        let worker = workers.find(w => w.key === body.key);
        if (!worker) {worker = {id:String(workers.length + 1),key:body.key,state:mode === 'asg' ? 'ready' : 'starting',draining:false,applied_revision:'0',last_seen_ms:String(Date.now()),idle_since_ms:String(Date.now()),active_attempts:0}; workers.push(worker);}
        worker.secret = body.token;
        result = worker;
      } else if (route === '/workers/sync') {
        const worker = workers.find(w => req.headers.authorization === 'Bearer ' + w.secret); assert.ok(worker);
        if (mode === 'docker' && !failCleanup && body.state === 'ready') {
          recoverReadyAt ||= Date.now() + 1200;
          if (Date.now() < recoverReadyAt) {
            readyFailures++; res.writeHead(503); res.end('{}'); return;
          }
        }
        worker.state = worker.draining && body.state === 'ready' ? 'drained' : body.state;
        worker.applied_revision = body.applied_revision; worker.last_seen_ms = String(Date.now());
        result = {version:1,provider_id:'1',worker_id:worker.id,paused,draining:worker.draining,config_revision:revision,config};
      } else if (route === '/claims') {
        const worker = workers.find(w => req.headers.authorization === 'Bearer ' + w.secret); assert.ok(worker);
        if (applied !== revision) result = {version:1,assignment:null};
        else {
          claims++; queued = 0;
          const now = Date.now();
          result = {version:1,assignment:claims <= 2 ? {version:1,attempt_id:String(claims),run_id:'1',job_id:String(claims),repository:'alice/demo',commit_sha:'a'.repeat(40),lease_until_ms:String(now + 60000),server_time_ms:String(now),state:'leased',job:{id:'build',name:'Build',runs_on:['self-hosted','linux'],timeout_minutes:1,steps:[{id:'check',name:'Check',run:'true',shell:'bash',working_directory:'.',env:{},timeout_minutes:0}]}} : null};
          if (claims === 1 && !failCleanup) {config = {...config,cpus:'1'}; revision = '2';}
        }
      } else if (/^\/workers\/[^/]+\/drain$/.test(route)) {
        const worker = workers.find(w => w.id === route.split('/')[2]);
        assert.equal(req.headers.authorization,'Bearer ' + providerToken);
        worker.draining = true; worker.state = 'drained'; result = {version:1};
      } else throw Error('unexpected route ' + route);
      res.writeHead(200, {'Content-Type':'application/json'}); res.end(JSON.stringify(result));
    } catch (err) {failure = err; res.writeHead(500); res.end('{}');}
  });
  let child, exited = false, output = '';
  try {
    await new Promise(r => server.listen(0,'127.0.0.1',r));
    const args = ['run','--server',`http://127.0.0.1:${server.address().port}`,'--allow-http','--name','test','--mode',mode,'--registration-token-file',tokenFile,'--state-dir',path.join(root,'controller'),'--workspace-root',path.join(root,'workspace'),'--docker',adapter,'--aws',adapter,'--runner-image','moonhub:runner'];
    if (mode === 'asg') args.push('--asg','on','--spot-asg','spot','--launch-template','lt-test','--instance-types','m6a.large');
    child = spawn(binary,args,{stdio:['ignore','pipe','pipe']});
    child.stdout.on('data',b => {output += b;}); child.stderr.on('data',b => {output += b;});
    child.on('exit',() => {exited = true;});
    const deadline = Date.now() + (mode === 'asg' ? 140000 : 30000);
    let standbySince;
    for (;;) {
      if (failure) throw failure;
      const st = state();
      if (mode === 'asg' && st.booted && revision === '1') {
        standbySince ??= Date.now();
        assert.equal(st.groups.on.desired, 1, 'idle standby capacity was lost');
        assert.ok(!st.calls.some(c => c[1] === 'terminate-instance-in-auto-scaling-group'), 'standby worker was retired by idle timeout');
        if (Date.now() - standbySince >= 31000) {
          config = {...config,standby_workers:'0'}; revision = '2';
        }
      }
      if (mode === 'asg' && st.calls.some(c => c[1] === 'terminate-instance-in-auto-scaling-group')) {
        await delay(6500);
        assert.equal(state().groups.on.desired,0,'stale group count recreated terminated instance');
        assert.equal(state().groups.spot.desired,0,'unfulfilled spot demand remained');
        const calls = state().calls;
        assert.ok(calls.findIndex(c => c[1] === 'set-desired-capacity' && c.includes('spot')) < calls.findIndex(c => c[1] === 'set-desired-capacity' && c.includes('on')));
        assert.ok(standbySince, 'no standby worker was provisioned for an empty queue');
        assert.equal(revision, '2');
        assert.ok(Date.now() - Number(workers[0].idle_since_ms) >= 30000, 'worker retired before its idle timeout');
        assert.ok(workers[0].draining); break;
      }
      if (mode === 'docker' && failCleanup && exited) {assert.equal(claims,1,'claim after cleanup failure'); assert.equal(st.volumes.length,1); break;}
      if (mode === 'docker' && !failCleanup && st.runs >= 2 && st.volumes.length === 0 && applied === '2') {assert.ok(st.containerArgs.includes('1')); break;}
      if (exited || Date.now() > deadline) throw Error(`${mode} timed out/stopped: ${output}; revisions=${observed}/${applied}/${revision}; claims=${claims}; workers=${JSON.stringify(workers.map(({secret,...w}) => w))}; calls=${JSON.stringify(st.calls.map(c => c.slice(0,3)))}`);
      await delay(100);
    }
    if (mode === 'docker' && !failCleanup) assert.ok(readyFailures > 0, 'no temporary Web outage was exercised');
    assert.equal(fs.statSync(path.join(root,'controller','provider-token')).mode & 0o777,0o600);
    assert.ok(!output.includes(providerToken));
    for (const directory of ['controller', 'workspace']) {
      assert.equal(fs.readFileSync(path.join(root, directory, '.existing'), 'utf8'), 'preserved');
    }
    console.log(`Managed ${mode}${failCleanup ? ' cleanup failure' : ''}: passed enrollment, revision sync and safe lifecycle.`);
  } finally {
    if (child && !exited) {child.kill('SIGTERM'); await Promise.race([new Promise(r => child.once('exit',r)),delay(20000).then(() => {if (!exited) child.kill('SIGKILL');})]);}
    server.closeAllConnections(); await new Promise(r => server.close(r));
    fs.rmSync(root,{recursive:true,force:true});
  }
}
(async () => {await scenario('docker'); await scenario('docker',true); await scenario('asg');})().catch(e => {console.error(e);process.exitCode=1;});
