const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const binary = path.resolve('_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe');
const delay = ms => new Promise(r => setTimeout(r, ms));
const registration = 'a'.repeat(64);

async function scenario(mode, failCleanup = false, stale = false, terminal = false, claimRace = false, environmentMode = '') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-managed-'));
  for (const directory of ['controller', 'workspace']) {
    fs.mkdirSync(path.join(root, directory), {mode:0o700});
    fs.writeFileSync(path.join(root, directory, '.existing'), 'preserved', {mode:0o600});
  }
  const stateFile = path.join(root, 'state.json');
  fs.writeFileSync(stateFile, JSON.stringify({calls: [], volumes: [], groups: {on: {desired:0, instances:[]}, spot: {desired:0, instances:[]}}, parameter:false}));
  if (stale) { const initial = JSON.parse(fs.readFileSync(stateFile)); initial.groups.on = {desired:1,instances:[{id:'i-test',lifecycle:'InService',scale_in_protected:true,instance_type:'m6a.large',template_version:'0'}]}; fs.writeFileSync(stateFile, JSON.stringify(initial)); }
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
if (args[0] === 'sts' && args[1] === 'get-caller-identity') result = {Account:'123456789012'};
else if (args[0] === 'ec2') {
  if (args[1] === 'describe-instance-types') result = [{cpus:2,memory_mib:8192,architectures:['x86_64']}];
  else if (args[1] === 'describe-launch-template-versions') result = [{image:'ami-test',tokens:'required',hop:1,disks:[{Encrypted:true,DeleteOnTermination:true}]}];
  else if (args[1] === 'describe-images') result = [{ architecture: 'x86_64', platform: null }];
  else if (args[1] === 'describe-instances') {
    const query = args[args.indexOf('--query') + 1];
    if (query.includes('MetadataOptions')) result = {State:'applied',HttpEndpoint:'disabled'};
    else if (query.includes('BlockDeviceMappings')) result = [['vol-ci',true]];
    else if (query.includes('State.Name')) result = ['terminated'];
    else result = [new Date(Date.now() - 240000).toISOString()];
  } else if (args[1] === 'describe-iam-instance-profile-associations' || args[1] === 'describe-volumes') result = [];
  else if (args[1] === 'modify-instance-metadata-options') assert.ok(state.booted);
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
  if (args[1] === 'describe-instance-information') { state.ssmChecks=(state.ssmChecks || 0)+1; result=state.ssmChecks<=2?[]:['i-test']; }
  else if (args[1] === 'put-parameter' || args[1] === 'send-command') {
    const request = JSON.parse(fs.readFileSync(args[args.indexOf('--cli-input-json') + 1].slice(7)));
    if (args[1] === 'put-parameter') {assert.equal(request.Type,'SecureString'); state.bootstrap = JSON.parse(request.Value); state.parameter = true;}
    else {assert.ok(!request.Parameters.commands.join('').includes(state.bootstrap.token)); state.booted = true; result={Command:{CommandId:'bootstrap-test'}};}
  } else if (args[1] === 'get-command-invocation') result = {Status:'Success'};
  else if (args[1] === 'describe-parameters') result = state.parameter ? ['/moonhub-runner/test/i-test'] : [];
  else if (args[1] === 'delete-parameter') state.parameter = false;
  else if (args[1] !== 'add-tags-to-resource') throw Error('unexpected SSM operation');
} else if (args[0] === 'volume') {
  if (args[1] === 'ls') result = state.volumes.join(String.fromCharCode(10));
  else if (args[1] === 'create') {state.volumes.push(args.at(-1)); result = args.at(-1);}
  else if (args[1] === 'rm') {
    if (${JSON.stringify(failCleanup)}) {save(); process.exit(1);}
    state.volumes = state.volumes.filter(v => v !== args.at(-1));
  } else throw Error('unexpected volume operation');
} else if (args[0] === 'run') {
  assert.ok(args.includes('--read-only')); assert.ok(args.includes('--cap-drop'));
  if(args.includes('--probe-environment')) {
    assert.ok(args.includes('none') && args.includes('10001:10001'));
    const debian=args.some(arg=>arg.endsWith('@sha256:'+'a'.repeat(64)));
    result=JSON.stringify({environment_protocol:1,architecture:'x64',os_release:debian && ${JSON.stringify(environmentMode)}!=='mismatch'?'ID=debian\\nVERSION_ID=12':'ID=ubuntu\\nVERSION_ID=24.04'});
    save(); console.log(result); process.exit(0);
  }
  const manifestMount = args.find(arg => arg.startsWith('type=bind,src='));
  const manifestPath = manifestMount.slice('type=bind,src='.length).split(',dst=')[0];
  assert.equal(fs.statSync(manifestPath).mode & 0o777, 0o444, 'non-root task cannot read a root-owned manifest');
  assert.equal(fs.statSync(require('node:path').dirname(manifestPath)).mode & 0o777, 0o700, 'host assignment directory must remain private');
  const assignment=JSON.parse(fs.readFileSync(manifestPath));
  if(assignment.environment) assert.ok(args.includes(assignment.environment.image),'task used another environment image');
  process.stdin.resume(); state.containerArgs = args; state.manifestPath = manifestPath; state.runs = (state.runs || 0) + 1;
  result = JSON.stringify({reported:true,conclusion:'success'});
} else if (args[0] === 'rm') {
  if (args.some(arg=>/^moonhub-pipeline-[0-9]+$/.test(arg)) && state.manifestPath && !fs.existsSync(state.manifestPath)) state.manifestRemovedBeforeContainer = true;
} else if (args[0] === 'ps') result = '';
else if (!['info','image','rm'].includes(args[0])) throw Error('unexpected adapter operation');
save();
if (result !== null) console.log(typeof result === 'string' ? result : JSON.stringify(result));
`, {mode:0o700});
  const workers = [];
  const environments = environmentMode ? ['debian-12','ubuntu-24.04'].map((selector,i)=>({id:String(i+11),is_default:i===0,environment:{name:selector,selector,architecture:'x64',image:'registry.example/runner@sha256:'+(i?'b':'a').repeat(64),labels:[]}})) : undefined;
  let providerToken, config, schema, revision = '1', observed = '0', applied = '0', claims = 0, queued = mode === 'asg' ? 0 : 1, paused = false, failure;
  let readyFailures = 0, recoverReadyAt = 0;
  let pendingClaim, releaseClaim, releaseTimer, raceConflicts = 0, raceWorker;
  const server = http.createServer(async (req, res) => {
    try {
      let text = ''; for await (const chunk of req) text += chunk;
      const body = JSON.parse(text), route = req.url.replace('/-/runner-api/v1', '');
      let result;
      const snapshot = () => ({version:1,id:'1',mode,paused,config_revision:revision,schema,config,queued_jobs:queued,workers,environments});
      if (route === '/providers/register') {
        assert.equal(req.headers.authorization, 'Bearer ' + registration);
        providerToken = body.provider_token; schema = body.schema; config = {...body.defaults};
        if (mode === 'asg') {config.purchase_policy = 'spot-with-on-demand-fallback'; config.spot_wait_seconds = '30'; config.idle_seconds = '30'; config.standby_workers = '1';}
        result = snapshot();
      } else if (route === '/providers/sync') {
        assert.equal(req.headers.authorization, 'Bearer ' + providerToken);
        if(environmentMode) assert.equal(body.environment_protocol,1);
        observed = body.observed_revision; applied = body.applied_revision;
        if (mode === 'asg' && state().booted) queued = 0;
        result = snapshot();
      } else if (route === '/workers/register') {
        assert.equal(req.headers.authorization, 'Bearer ' + providerToken);
        assert.notEqual(body.token, providerToken);
        if (mode === 'asg' && !stale) assert.ok(state().ssmChecks >= 3, 'worker registered before SSM online');
        let worker = workers.find(w => w.key === body.key);
        if (!worker) {worker = {id:String(workers.length + 1),key:body.key,state:stale ? 'busy' : mode === 'asg' ? 'ready' : 'starting',draining:false,applied_revision:'0',last_seen_ms:String(Date.now()),idle_since_ms:String(Date.now()),active_attempts:stale ? 1 : 0}; workers.push(worker);}
        worker.secret = body.token;
        result = worker;
      } else if (route === '/workers/sync') {
        const worker = workers.find(w => req.headers.authorization === 'Bearer ' + w.secret); assert.ok(worker);
        if(environmentMode && body.state==='ready') assert.deepEqual(body.environments,['11','12']);
        if (claimRace && pendingClaim && body.state === 'ready') {
          // The server has leased the task, but its claim response is still in
          // flight. A concurrent ready heartbeat must not retire this worker.
          assert.equal(worker.key, raceWorker);
          assert.equal(worker.state, 'busy');
          raceConflicts++; res.writeHead(409); res.end('{}');
          releaseTimer = setTimeout(() => {pendingClaim = false; releaseClaim();}, 500);
          return;
        }
        if (claimRace && body.state === 'ready' && worker.active_attempts > 0) {
          const st = state();
          assert.equal(st.runs, claims, 'worker became ready before executing its claimed task');
          assert.equal(st.volumes.length, 0, 'worker became ready before workspace cleanup');
          assert.deepEqual(fs.readdirSync(path.join(root, 'workspace')), ['.existing'], 'worker became ready before assignment cleanup');
          worker.active_attempts = 0;
        }
        if (terminal && body.state === 'ready') {
          worker.state='failed';res.writeHead(409);res.end('{}');return;
        }
        if (mode === 'docker' && !failCleanup && !claimRace && body.state === 'ready') {
          recoverReadyAt ||= Date.now() + 1200;
          if (Date.now() < recoverReadyAt) {
            readyFailures++; res.writeHead(503); res.end('{}'); return;
          }
        }
        worker.state = worker.draining && body.state === 'ready' ? 'drained' : body.state;
        worker.applied_revision = body.applied_revision; worker.last_seen_ms = String(Date.now());
        result = {version:1,provider_id:'1',worker_id:worker.id,paused,draining:worker.draining,config_revision:revision,config,environments};
      } else if (route === '/claims') {
        const worker = workers.find(w => req.headers.authorization === 'Bearer ' + w.secret); assert.ok(worker);
        if (applied !== revision || claimRace && claims >= 2) result = {version:1,assignment:null};
        else {
          claims++; queued = 0;
          const now = Date.now();
          result = {version:1,assignment:claims <= 2 ? {version:1,attempt_id:String(claims),run_id:'1',job_id:String(claims),repository:'alice/demo',commit_sha:'a'.repeat(40),lease_until_ms:String(now + 60000),server_time_ms:String(now),state:'leased',job:{id:'build',name:'Build',runs_on:['self-hosted','linux'],timeout_minutes:1,steps:[{id:'check',name:'Check',run:'true',shell:'bash',working_directory:'.',env:{},timeout_minutes:0}]}} : null};
          if(environmentMode) {
            assert.deepEqual(body.environments,['11','12']);
            if(result.assignment){result.assignment.version=13;result.assignment.environment=environments[claims-1].environment;}
          }
          if (claims === 1 && !failCleanup) {config = {...config,cpus:'1'}; revision = '2';}
          if (claimRace && claims <= 2) {
            assert.equal(workers.length, 1, 'claim race replaced the worker');
            worker.state = 'busy'; worker.active_attempts = 1;
            if (claims === 1) {
              raceWorker = worker.key; pendingClaim = true;
              console.log('Claim race: first task leased; holding its response until a background ready heartbeat receives 409.');
              await new Promise(resolve => {releaseClaim = resolve;});
            } else assert.equal(worker.key, raceWorker, 'second task used a different worker');
          }
        }
      } else if (/^\/workers\/[^/]+\/isolation$/.test(route)) {
        assert.equal(req.headers.authorization,'Bearer ' + providerToken);
        assert.equal(body.revision, revision);
        result = {version:1};
      } else if (/^\/workers\/[^/]+\/drain$/.test(route)) {
        const worker = workers.find(w => w.id === route.split('/')[2]);
        assert.equal(req.headers.authorization,'Bearer ' + providerToken);
        worker.draining = true; if (!stale) worker.state = 'drained'; result = {version:1};
      } else throw Error('unexpected route ' + route);
      res.writeHead(200, {'Content-Type':'application/json'}); res.end(JSON.stringify(result));
    } catch (err) {failure = err; res.writeHead(500); res.end('{}');}
  });
  let child, exited = false, output = '';
  try {
    await new Promise(r => server.listen(0,'127.0.0.1',r));
    const args = ['run','--server',`http://127.0.0.1:${server.address().port}`,'--allow-http','--name','test','--mode',mode,'--registration-token-file',tokenFile,'--state-dir',path.join(root,'controller'),'--workspace-root',path.join(root,'workspace'),'--docker',adapter,'--aws',adapter,'--runner-image','moonhub:runner'];
    if (mode === 'asg') args.push('--linux-ci','--asg','on','--spot-asg','spot','--launch-template','lt-test','--instance-types','m6a.large','--parameter-prefix','/moonhub-runner/test');
    child = spawn(binary,args,{stdio:['ignore','pipe','pipe']});
    child.stdout.on('data',b => {output += b;}); child.stderr.on('data',b => {output += b;});
    child.on('exit',() => {exited = true;});
    const deadline = Date.now() + (terminal ? 6000 : mode === 'asg' ? 140000 : 30000);
    let standbySince;
    for (;;) {
      if (failure) throw failure;
      const st = state();
      if(environmentMode==='mismatch' && exited) {assert.equal(claims,0,'mislabeled image claimed a job');break;}
      if (stale && workers[0]?.draining) {
        assert.equal(workers[0].active_attempts, 1);
        assert.ok(!st.calls.some(c => c[1] === 'terminate-instance-in-auto-scaling-group'), 'unknown busy instance terminated without cleanup');
        assert.ok(!st.booted, 'obsolete instance bootstrapped using the new template OS');
        break;
      }
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
      if (terminal && exited) {assert.equal(claims,0,'claim after worker retirement');assert.equal(workers[0].state,'failed');break;}
      if (mode === 'docker' && failCleanup && exited) {assert.equal(claims,1,'claim after cleanup failure'); assert.equal(st.volumes.length,1); break;}
      if (mode === 'docker' && !failCleanup && st.runs >= 2 && st.volumes.length === 0 && applied === '2' && (!claimRace || workers[0]?.active_attempts === 0)) {
        assert.ok(st.containerArgs.includes('1'));
        if(environmentMode) {
          const tasks=st.calls.filter(c=>c[0]==='run' && !c.includes('--probe-environment'));
          assert.equal(tasks.length,2);
          assert.ok(tasks[0].includes(environments[0].environment.image));
          assert.ok(tasks[1].includes(environments[1].environment.image));
          assert.equal(workers.length,1,'switching distributions added worker capacity');
          assert.ok(st.calls.filter(c=>c.includes('--probe-environment')).length>=4,'revision change skipped environment preparation');
        }
        if (claimRace) {
          assert.equal(raceConflicts, 1, 'claim response was not held across one conflicting background heartbeat');
          assert.equal(workers.length, 1, 'claim race replaced the worker');
          assert.equal(workers[0].key, raceWorker);
          assert.equal(claims, 2); assert.equal(st.runs, 2);
          assert.equal(workers[0].active_attempts, 0, 'second task never acknowledged cleanup');
          for (const id of ['1', '2']) assert.ok(st.calls.some(c => c[0] === 'rm' && c.includes('moonhub-pipeline-' + id)), 'task container was not removed');
          assert.deepEqual(fs.readdirSync(path.join(root, 'workspace')), ['.existing'], 'assignment directory survived cleanup');
        }
        break;
      }
      if (exited || Date.now() > deadline) throw Error(`${mode}${claimRace ? ' claim race' : ''} timed out/stopped: ${output}; revisions=${observed}/${applied}/${revision}; claims=${claims}; raceConflicts=${raceConflicts}; runs=${st.runs || 0}; workers=${JSON.stringify(workers.map(({secret,...w}) => w))}; calls=${JSON.stringify(st.calls.map(c => c.slice(0,3)))}`);
      await delay(100);
    }
    if (mode === 'asg' && !stale) assert.ok(state().ssmChecks >= 3, 'offline SSM startup delay was not exercised');
    assert.equal(state().manifestRemovedBeforeContainer, undefined, 'assignment mount was removed before container cleanup');
    if (mode === 'docker' && !failCleanup && !terminal && !claimRace && environmentMode!=='mismatch') assert.ok(readyFailures > 0, 'no temporary Web outage was exercised');
    assert.equal(fs.statSync(path.join(root,'controller','provider-token')).mode & 0o777,0o600);
    assert.ok(!output.includes(providerToken));
    for (const directory of ['controller', 'workspace']) {
      assert.equal(fs.readFileSync(path.join(root, directory, '.existing'), 'utf8'), 'preserved');
    }
    console.log(`Managed ${mode}${environmentMode ? ' environments '+environmentMode : claimRace ? ' claim race' : terminal ? ' retired worker' : failCleanup ? ' cleanup failure' : stale ? ' stale snapshot' : ''}: passed enrollment, revision sync and safe lifecycle.`);
  } finally {
    clearTimeout(releaseTimer); releaseClaim?.();
    if (child && !exited) {child.kill('SIGTERM'); await Promise.race([new Promise(r => child.once('exit',r)),delay(20000).then(() => {if (!exited) child.kill('SIGKILL');})]);}
    server.closeAllConnections(); await new Promise(r => server.close(r));
    fs.rmSync(root,{recursive:true,force:true});
  }
}
(async () => {if(process.argv.includes('--environments')) {await scenario('docker',false,false,false,false,'multiple');await scenario('docker',false,false,false,false,'mismatch');return;}if(process.argv.includes('--asg-boot')) {await scenario('asg');return;}if(process.argv.includes('--claim-race')) {await scenario('docker',false,false,false,true);return;}if(process.argv.includes('--terminal')) {await scenario('docker',false,false,true);return;}await scenario('docker'); await scenario('docker',true); await scenario('asg'); await scenario('asg',false,true);await scenario('docker',false,false,true);await scenario('docker',false,false,false,true);await scenario('docker',false,false,false,false,'multiple');await scenario('docker',false,false,false,false,'mismatch');})().catch(e => {console.error(e);process.exitCode=1;});
