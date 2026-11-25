// Real native ASG controller with strict HTTP/AWS fixtures. Privileged execution
// is independently tested by linux-ci-smoke.cjs; no cloud resources are created.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {spawn} = require('node:child_process');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const binary = path.resolve('_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe');
async function scenario(failed, vanished = false, windows = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ci-lifecycle-'));
  const stateFile = path.join(root, 'aws.json');
  fs.writeFileSync(stateFile, JSON.stringify({calls: [], disabled: false, terminated: false, booted: false}));
  const state = () => JSON.parse(fs.readFileSync(stateFile));
  const saveState = value => {
    const temporary = stateFile + '.parent';
    fs.writeFileSync(temporary, JSON.stringify(value)); fs.renameSync(temporary, stateFile);
  };
  const adapter = path.join(root, 'aws');
  fs.writeFileSync(adapter, `#!${process.execPath}
const fs=require('node:fs'),assert=require('node:assert/strict');
const file=${JSON.stringify(stateFile)},args=process.argv.slice(2),s=JSON.parse(fs.readFileSync(file));s.calls.push(args.slice(0,2));
const windows=${windows};
const save = () => {
 const temporary=file+'.'+process.pid;
 const handle=fs.openSync(temporary,'w');
 // Widen the former truncate/write race while readers keep seeing the old
 // complete document until the atomic rename publishes the new state.
 Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,20);
 fs.writeFileSync(handle,JSON.stringify(s));fs.closeSync(handle);fs.renameSync(temporary,file);
};
let result=null;
if(args[0]==='sts')result={Account:'123456789012'};
else if(args[0]==='ec2'){
 if(args[1]==='describe-instance-types')result=[{cpus:2,memory_mib:8192,architectures:['x86_64']}];
 else if(args[1]==='describe-launch-template-versions'){
   assert.ok(args.at(args.indexOf('--query')+1).includes('disks:'));
   result=[{image:'ami-ci',tokens:'required',hop:1,disks:[{Encrypted:true,DeleteOnTermination:true}]}];
 }
 else if(args[1]==='describe-images')result=[{architecture:'x86_64',platform:windows?'windows':null}];
 else if(args[1]==='modify-instance-metadata-options'){assert.ok(s.booted,'disabled IMDS before bootstrap download');s.disabled=true;}
 else if(args[1]==='describe-iam-instance-profile-associations')result=s.disassociated?[]:[{state:'associated',id:'iip-assoc-fixture'}];
 else if(args[1]==='disassociate-iam-instance-profile'){assert.ok(s.disabled);s.disassociated=true;}
 else if(args[1]==='describe-instances'){
   const q=args.at(args.indexOf('--query')+1);
   if(q.includes('MetadataOptions'))result={State:'applied',HttpEndpoint:s.disabled?'disabled':'enabled'};
   else if(q.includes('State.Name'))result=[s.terminated?'terminated':'running'];
   else if(q.includes('BlockDeviceMappings'))result=[['vol-ci',true]];
   else result=[new Date().toISOString()];
 }
 else if(args[1]==='describe-volumes'){assert.ok(s.terminated);result=s.diskChecked?[]:['vol-ci'];s.diskChecked=true;}
 else throw Error('unexpected EC2 '+args[1]);
}else if(args[0]==='autoscaling'){
 if(args[1]==='describe-auto-scaling-groups')result=[{name:'ci',min:0,max:1,desired:s.terminated?0:1,instances:s.terminated?[]:[{id:'i-ci',lifecycle:'InService',scale_in_protected:true,instance_type:'m6a.large',template_version:'1'}]}];
 else if(args[1]==='terminate-instance-in-auto-scaling-group'){s.terminated=true;assert.ok(s.disabled);}
 else if(args[1]!=='update-auto-scaling-group')throw Error('unexpected ASG '+args[1]);
}else if(args[0]==='ssm'){
 if(args[1]==='describe-instance-information')result=['i-ci'];
 else if(args[1]==='put-parameter'){const b=JSON.parse(fs.readFileSync(args[args.indexOf('--cli-input-json')+1].slice(7)));const p=JSON.parse(b.Value);assert.equal(p.linux_ci,!windows);if(windows){assert.equal(p.windows_vm,true);assert.equal(p.runner_os,'windows');}else assert.equal(p.runner_image,'ci:configured');s.workerToken=p.token;}
 else if(args[1]==='add-tags-to-resource'){assert.ok(args.includes('Key=MoonHubInstanceArn,Value=arn:aws:ec2:us-west-2:123456789012:instance/i-ci'));}
 else if(args[1]==='send-command'){const b=JSON.parse(fs.readFileSync(args[args.indexOf('--cli-input-json')+1].slice(7)));assert.ok(b.Parameters.commands[0].includes(windows?'ci-host.ps1':'moonhub-ci-host'));assert.ok(!b.Parameters.commands[0].includes(s.workerToken));s.booted=true;result={Command:{CommandId:'command-ci'}};}
 else if(args[1]==='get-command-invocation')result={Status:'Success'};
 else if(args[1]==='delete-parameter'){
   if(!s.deleteFailed){s.deleteFailed=true;save();process.exit(1);}
   s.deleted=true;
 }
 else if(args[1]==='describe-parameters')result=s.deleted?[]:['/moonhub-runner/ci/i-ci'];
 else throw Error('unexpected SSM '+args[1]);
}else throw Error('unexpected AWS '+args[0]);
save();if(result!==null)console.log(JSON.stringify(result));
`, {mode: 0o700});
  const registration = path.join(root, 'registration'); fs.writeFileSync(registration, 'a'.repeat(64), {mode: 0o600});
  let config, schema, providerToken, worker, armed = false, status = '', error, child, exited = false, output = '';
  const server = http.createServer(async (req, res) => {
    try {
      let text = ''; for await (const chunk of req) text += chunk;
      const body = JSON.parse(text), route = req.url.replace('/-/runner-api/v1', ''); let result;
      const snapshot = () => ({version: 1, id: '1', mode: 'asg', paused: false, config_revision: '1', schema, config,
        queued_jobs: armed ? 0 : 1, workers: worker ? [worker] : []});
      if (route === '/providers/register') {
        assert.equal(req.headers.authorization, 'Bearer ' + 'a'.repeat(64)); providerToken = body.provider_token;
        schema = body.schema; config = windows ? body.defaults : {...body.defaults, runner_image: 'ci:configured'};
        assert.equal(config.execution_mode, windows ? 'windows-vm' : 'linux-ci'); result = snapshot();
      } else {
        assert.equal(req.headers.authorization, 'Bearer ' + providerToken);
        if (route === '/providers/sync') {status = body.status; result = snapshot();}
        else if (route === '/workers/register') {
          worker ||= {id: '1', key: 'i-ci', state: 'starting', draining: false, applied_revision: '0',
            last_seen_ms: String(Date.now()), idle_since_ms: String(Date.now()), active_attempts: 0}; result = worker;
        } else if (route === '/workers/1/isolation') {
          assert.ok(state().disabled, 'armed before externally disabling metadata');
          assert.ok(state().disassociated, 'armed before detaching the bootstrap role');
          assert.ok(state().deleted, 'armed with a live bootstrap parameter');
          assert.ok(fs.existsSync(path.join(root, 'controller/i-ci.ci-volumes')));
          assert.equal(body.revision, '1'); assert.match(body.controller_id, /^[a-f0-9]{32}$/);
          armed = true;
          if (vanished) {
            const current = state(); current.terminated = true;
            saveState(current);
          }
          // A compromised guest can keep heartbeating and never acknowledge
          // cleanup. Server-fenced consumption still permits outside retirement.
          worker = {...worker, state: failed ? 'failed' : 'busy', draining: !vanished, active_attempts: 0, last_seen_ms: String(Date.now())};
          result = {version: 1};
        } else throw Error('unexpected route ' + route);
      }
      res.writeHead(200, {'Content-Type': 'application/json'}); res.end(JSON.stringify(result));
    } catch (e) {error = e; res.writeHead(500); res.end('{}');}
  });
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    child = spawn(binary, ['run', windows ? '--windows-vm' : '--linux-ci', '--server', 'http://127.0.0.1:' + server.address().port, '--allow-http',
      '--name', 'ci', '--mode', 'asg', '--registration-token-file', registration, '--state-dir', path.join(root, 'controller'),
      '--workspace-root', path.join(root, 'workspace'), '--aws', adapter, '--asg', 'ci', '--launch-template', 'lt-ci',
      '--instance-types', 'm6a.large', '--runner-image', 'ci:startup'], {stdio: ['ignore', 'pipe', 'pipe']});
    child.stdout.on('data', x => {output += x;}); child.stderr.on('data', x => {output += x;});
    child.once('exit', () => {exited = true;});
    const deadline = Date.now() + (vanished ? 25000 : 90000);
    while (!state().deleted || fs.existsSync(path.join(root, 'controller/i-ci.ci-retire'))) {
      if (error) throw error;
      if (exited || Date.now() > deadline) throw Error('CI lifecycle failed: ' + status + ' ' + output);
      await delay(100);
    }
    assert.ok(armed); assert.ok(state().terminated);
    if (vanished) assert.equal(state().calls.filter(x => x[1] === 'terminate-instance-in-auto-scaling-group').length, 0);
    assert.ok(state().deleteFailed, 'cleanup retry was not exercised');
    assert.equal(state().calls.filter(x => x[1] === 'send-command').length, 1, 'bootstrap command was replayed');
    assert.ok(!fs.existsSync(path.join(root, 'controller/i-ci.token')));
    assert.ok(!output.includes(providerToken)); assert.ok(!output.includes(state().workerToken));
    assert.ok(state().diskChecked, 'disk deletion was not checked');
    assert.ok(!fs.existsSync(path.join(root, 'controller/i-ci.ci-volumes')));
    console.log((windows ? 'WINDOWS_VM' : 'LINUX_CI') + '_EXTERNAL_RETIREMENT_' + (vanished ? 'UNEXPECTED_TERMINATION' : failed ? 'FAILURE' : 'COMPLETION') + '_OK');
  } finally {
    if (child && !exited) {child.kill('SIGTERM'); await Promise.race([new Promise(resolve => child.once('exit', resolve)), delay(10000)]); if (!exited) child.kill('SIGKILL');}
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); fs.rmSync(root, {recursive: true, force: true});
  }
}
(async () => {
  if (process.argv.includes('--unexpected-termination')) { await scenario(false, true); return; }
  if (process.argv.includes('--windows-vm')) { await scenario(false, false, true); return; }
  await scenario(false); await scenario(true); await scenario(false, true);
})().catch(e => {console.error(e); process.exitCode = 1;});
