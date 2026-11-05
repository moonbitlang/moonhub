// Real Windows Docker acceptance: the same worker executes three attempts,
// removes each container + named workspace volume before ready, then drains.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const docker = args => execFileSync('docker.exe', ['--host','npipe:////./pipe/docker_engine',...args], {encoding:'utf8', timeout:30000}).trim();
const image = process.env.MOONHUB_RUNNER_IMAGE || 'moonhub:runner-windows';
const binary = path.resolve('.tmp/windows-runner/bin/moonhub-runner.exe');
const standalone = process.argv.includes('--standalone');
const secret = crypto.randomBytes(20).toString('hex');
const registration = crypto.randomBytes(32).toString('hex');
let workerToken = crypto.randomBytes(32).toString('hex');
let providerToken, providerConfig, providerSchema, workerKey, workerState='starting', workerRevision='0';
const step = (id, run, shell = '', extra = {}) => ({ id, name:id, run, shell, uses:'', working_directory:'.', env:{}, timeout_minutes:0, ...extra });

async function main() {
  assert.equal(process.platform,'win32');
  let daemon,lastDaemonError;
  const daemonDeadline=Date.now()+120000;
  do {
    try {daemon=JSON.parse(docker(['info','--format','{{json .}}']));break;}
    catch(error){lastDaemonError=error;console.log('Waiting for the local Windows Docker engine after image build');await delay(2000);}
  }while(Date.now()<daemonDeadline);
  if(!daemon)throw lastDaemonError;
  assert.equal(daemon.OSType,'windows');
  const nat = JSON.parse(docker(['network','inspect','nat']))[0];
  const gateway = nat.IPAM.Config.find(config => config.Gateway)?.Gateway;
  assert.ok(gateway && /^[\d.]+$/.test(gateway),'NAT host gateway is missing');
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'moonhub Windows worker '));
  const source = path.join(root,'source'); fs.mkdirSync(source);
  fs.writeFileSync(path.join(source,'source.txt'),'pinned source\n');
  fs.mkdirSync(path.join(source,'action'));
  fs.writeFileSync(path.join(source,'action/action.yml'),'name: Probe\nruns:\n  using: node20\n  main: main.cjs\n  post: post.cjs\n');
  fs.writeFileSync(path.join(source,'action/main.cjs'), `require('node:assert/strict').equal(process.platform,'win32'); require('node:assert/strict').equal(process.versions.node.split('.')[0],'20'); console.log('windows-action-main');`);
  fs.writeFileSync(path.join(source,'action/post.cjs'), `console.log('windows-action-post');`);
  const git = args => execFileSync('git', args, {cwd:source,encoding:'utf8',timeout:30000}).trim();
  git(['init','--quiet']); git(['add','.']);
  git(['-c','user.name=Runner smoke','-c','user.email=runner@example.invalid','commit','--quiet','-m','fixture']);
  const sha = git(['rev-parse','HEAD']);
  git(['bundle','create',path.join(root,'source.bundle'),'HEAD']);
  git(['archive','--format=tar','--output='+path.join(root,'source.tar'),'HEAD']);
  const archive = fs.readFileSync(path.join(root,'source.tar'));
  const bundle = fs.readFileSync(path.join(root,'source.bundle'));
  const attempts = new Map();
  let claims=0, readyAfterCleanup=0, completed=0, drained=false, drainCount=0, failure, worker, output='';
  const server = http.createServer(async(req,res)=>{
    try {
      const route = req.url.split('/').pop();
      const id = req.url.match(/\/attempts\/(\d+)\//)?.[1];
      const attempt = attempts.get(id);
      const providerRoute = /\/providers\/(register|sync)$/.test(req.url) || /\/workers\/(register|[^/]+\/drain)$/.test(req.url);
      const credential = req.url.endsWith('/providers/register') ? registration : providerRoute ? providerToken : attempt ? attempt.token : workerToken;
      assert.equal(req.headers.authorization, `Bearer ${credential}`);
      if (req.method === 'GET') {
        const bytes = route === 'source-bundle' ? bundle : archive;
        assert.ok(['source','source-bundle'].includes(route));
        res.writeHead(200, {'Content-Length':bytes.length,Connection:'close'}); res.end(bytes); return;
      }
      let text=''; for await (const chunk of req) {text+=chunk; assert.ok(text.length<65536);}
      const body=JSON.parse(text), now=Date.now(); let reply;
      const providerSnapshot = () => ({version:1,id:'1',mode:'docker',paused:false,config_revision:'1',schema:providerSchema,config:providerConfig,queued_jobs:Math.max(0,3-completed),workers:workerKey?[{id:'1',key:workerKey,state:workerState,draining:drained,applied_revision:workerRevision,last_seen_ms:String(now),idle_since_ms:String(now),active_attempts:0}]:[]});
      if (req.url.endsWith('/providers/register')) {
        assert.equal(standalone,true); assert.equal(body.mode,'docker'); assert.equal(body.name,'windows-pc-smoke');
        providerToken=body.provider_token;providerSchema=body.schema;providerConfig={...body.defaults,cpus:'1',memory_mib:'2048'};reply=providerSnapshot();
      } else if (req.url.endsWith('/providers/sync')) reply=providerSnapshot();
      else if (req.url.endsWith('/workers/register')) {
        workerToken=body.token;workerKey=body.key;reply={version:1,id:'1'};
      } else if (/\/workers\/[^/]+\/drain$/.test(req.url)) reply={version:1};
      else if (req.url.endsWith('/workers/sync')) {
        workerState=body.state;workerRevision=body.applied_revision;
        if (body.state === 'ready' && completed > readyAfterCleanup) {
          assert.equal(docker(['ps','-aq','--filter','name=^moonhub-pipeline-']), '', 'task container survived readiness');
          assert.equal(docker(['volume','ls','-q','--filter','label=io.moonhub.pipeline.workspace=1']), '', 'workspace survived readiness');
          assert.deepEqual(fs.readdirSync(standalone?path.join(install,'workspace'):path.join(root,'workspace')),[], 'assignment directory survived readiness');
          readyAfterCleanup=completed;
        }
        if (body.state==='drained') {drained=true;drainCount++;}
        if (body.state==='failed') throw Error('worker failed before draining');
        // Request drain only after the cancelled attempt has cleaned up and
        // acknowledged ready, so this test proves reuse after cancellation too.
        reply={version:1,provider_id:'1',worker_id:'1',paused:false,draining:readyAfterCleanup===3,config_revision:'1',config:{runner_image:image,cpus:'1',memory_mib:'2048'}};
      } else if (route==='claims') {
        assert.equal(body.runner_os,'windows');
        assert.equal(readyAfterCleanup,completed,'worker claimed before cleanup');
        if (claims===3) reply={version:1,assignment:null};
        else {
          const id=String(++claims), cancel=claims===3;
          const probe = [
            ...(claims===1 ? ["& moon version --all; if ($LASTEXITCODE -ne 0) { throw 'MoonBit setup failed' }"] : []),
            "if (Test-Path stale.txt) { throw 'Workspace was reused' }",
            "if ((Get-Content source.txt -Raw).Trim() -ne 'pinned source') { throw 'Source checkout failed' }",
            "if ($env:MOONHUB_PROVIDER_TOKEN -or $env:AWS_SECRET_ACCESS_KEY) { throw 'Host environment leaked' }",
            `Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ProcessProbe { [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid); }'`,
            "foreach ($agent in (Get-Process -Name moonhub-runner)) { if ([ProcessProbe]::OpenProcess(0x10, $false, $agent.Id) -ne [IntPtr]::Zero -or [ProcessProbe]::OpenProcess(0x40000, $false, $agent.Id) -ne [IntPtr]::Zero) { throw 'Agent memory or DACL is accessible to task code' } }",
            "foreach ($launcher in (Get-Process -Name moonhub-runner-step)) { foreach ($access in @(0x1,0x40,0x40000)) { if ([ProcessProbe]::OpenProcess($access, $false, $launcher.Id) -ne [IntPtr]::Zero) { throw 'Launcher termination, handles or DACL are accessible to task code' } } }",
            ...(claims===2 ? ["if (-not $env:SMOKE_SECRET) { throw 'Secret delivery failed' }; Write-Output $env:SMOKE_SECRET"] : []),
            "if ($env:RUNNER_OS -ne 'Windows') { throw 'Runner OS missing' }",
            "[IO.File]::WriteAllText((Join-Path $pwd 'stale.txt'), 'attempt')",
            `Write-Output 'container-ready-${id}'`,
            ...(cancel ? ['Start-Sleep -Seconds 40'] : []),
          ].join('\n');
          const steps=[...(claims===1?[step('moonbit','', '',{uses:'moonhub/setup-moonbit@v1',moonbit_version:fs.readFileSync('deploy/base.Dockerfile','utf8').match(/^ARG MOONBIT_VERSION=([^\r\n]+)/m)[1]})]:[]),step('probe',probe,'',claims===2?{secret_env:{SMOKE_SECRET:'SMOKE_SECRET'}}:{}),...(cancel?[]:[step('bash','test -f source.txt; test "$RUNNER_OS" = Windows','bash')])];
          // Attempt 2 exercises the complete v5 bundle + local JavaScript action path.
          if (claims===2) steps.push(step('action','', '',{uses:'./action',remote:true}));
          const record={token:body.attempt_token,execution:'',sequence:0n,logs:'',conclusion:'',cancel,started:now};
          attempts.set(id,record); console.log('Claimed Windows attempt '+id);
          reply={version:1,assignment:{version:claims===2?5:3,attempt_id:id,run_id:id,job_id:id,repository:'test/probe',commit_sha:sha,state:'leased',lease_until_ms:String(now+60000),server_time_ms:String(now),job:{id:'build',name:'Build',runs_on:['self-hosted','windows'],timeout_minutes:8,steps}}};
        }
      } else {
        assert.ok(attempt,'unknown attempt');
        if(route==='start') {attempt.execution=body.execution_id;console.log('Started Windows attempt '+id);}
        if(route==='secrets') { res.writeHead(200,{'Content-Type':'application/json',Connection:'close'});res.end(JSON.stringify({version:1,env:{SMOKE_SECRET:secret}}));return; }
        attempt.lastOperation=route;
        if(route==='logs') {
          assert.equal(BigInt(body.sequence),attempt.sequence+1n); attempt.sequence++;
          assert.ok(!body.text.includes(attempt.token)); assert.ok(!body.text.includes('controller-only-sentinel')); assert.ok(!body.text.includes(secret));
          attempt.logs+=body.text; if(body.text.includes('container-ready-')) console.log('Probe ready for Windows attempt '+id);
        }
        if(route==='complete') {
          assert.equal(BigInt(body.last_log_sequence),attempt.sequence);
          assert.equal(body.conclusion,attempt.cancel?'cancelled':'success',attempt.logs);
          assert.ok(attempt.logs.includes('container-ready-'+id),attempt.logs);
          if(id==='2') {assert.ok(attempt.logs.includes('windows-action-main')); assert.ok(attempt.logs.includes('windows-action-post'));}
          attempt.conclusion=body.conclusion; completed++;console.log('Completed Windows attempt '+id+': '+body.conclusion);
        }
        reply={version:1,execution_id:attempt.execution,attempt_id:id,state:attempt.conclusion?'completed':'running',lease_until_ms:String(now+60000),server_time_ms:String(now),deadline_ms:String(attempt.started+480000),cancel_requested:attempt.cancel && attempt.logs.includes('container-ready-3'),log_sequence:String(attempt.sequence),conclusion:attempt.conclusion};
      }
      res.writeHead(200,{'Content-Type':'application/json',Connection:'close'}); res.end(JSON.stringify(reply));
    } catch(error) {failure=error;res.writeHead(500);res.end('fixture rejected request');}
  });
  await new Promise(resolve=>server.listen(0,'0.0.0.0',resolve));
  const port=server.address().port, rule='MoonHubRunnerSmoke-'+crypto.randomBytes(6).toString('hex');
  // A PS7 parent exports its own module directories. Windows PowerShell 5.1
  // must load the matching inbox modules rather than PS7's Security/Utility DLLs.
  const powerShellEnv={...process.env};
  for(const key of Object.keys(powerShellEnv))if(key.toLowerCase()==='psmodulepath')delete powerShellEnv[key];
  powerShellEnv.PSModulePath=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/Modules');
  const ps = command=>execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],{stdio:'inherit',timeout:30000,env:powerShellEnv});
  const taskName='MoonHubStandaloneSmoke'+crypto.randomBytes(6).toString('hex');
  const install=path.join(process.env.ProgramData || 'C:/ProgramData',taskName+' install');
  const runPowerShell = args => execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',...args],{encoding:'utf8',timeout:240000,env:powerShellEnv});
  const quote = value => "'"+value.replaceAll("'","''")+"'";
  let taskInstalled=false;
  try {
    ps(`New-NetFirewallRule -Name '${rule}' -DisplayName '${rule}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort ${port} | Out-Null`);
    const bootstrap=path.join(root,'bootstrap.json');
    fs.writeFileSync(bootstrap,JSON.stringify({server:`http://${gateway}:${port}`,token:workerToken,allow_http:true,runner_image:image,runner_os:'windows'}));
    let exited=false, exitCode, closed;
    if(standalone) {
      const tokenFile=path.join(root,'registration');fs.writeFileSync(tokenFile,registration);
      // A precreated root or child controlled by an unprivileged identity
      // must fail before reading provider.json or running copied executables.
      for(const target of [install,path.join(install,'bin')]) {
        runPowerShell(['-Command',`New-Item -ItemType Directory -Force ${quote(path.join(install,'bin'))} | Out-Null; $rootAcl=[Security.AccessControl.DirectorySecurity]::new(); $rootAcl.SetAccessRuleProtection($true,$false); $rootAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')); foreach($sid in 'S-1-5-18','S-1-5-32-544'){$rootAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}; Set-Acl -LiteralPath ${quote(install)} -AclObject $rootAcl; & icacls.exe ${quote(target)} /setowner '*S-1-5-32-545' | Out-Null; if($LASTEXITCODE -ne 0){throw 'Fixture owner change failed'}`]);
        assert.throws(()=>runPowerShell(['-File',path.resolve('.tmp/windows-runner/install-provider.ps1'),'-Bundle',path.resolve('.tmp/windows-runner'),'-RunnerImage',image,'-Server',`http://${gateway}:${port}`,'-Name','windows-pc-smoke','-RegistrationTokenFile',tokenFile,'-Directory',install,'-TaskName',taskName,'-AllowHttp','-NoStart']),/untrusted owner/);
        assert.equal(fs.existsSync(path.join(install,'provider.json')),false);
        fs.rmSync(install,{recursive:true,force:true});
      }
      runPowerShell(['-Command',`New-Item -ItemType Directory -Force ${quote(install)} | Out-Null; & icacls.exe ${quote(install)} /setowner '*S-1-5-32-544' | Out-Null; & icacls.exe ${quote(install)} /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null; if($LASTEXITCODE -ne 0){throw 'Fixture permissions failed'}`]);
      assert.throws(()=>runPowerShell(['-File',path.resolve('.tmp/windows-runner/install-provider.ps1'),'-Bundle',path.resolve('.tmp/windows-runner'),'-RunnerImage',image,'-Server',`http://${gateway}:${port}`,'-Name','windows-pc-smoke','-RegistrationTokenFile',tokenFile,'-Directory',install,'-TaskName',taskName,'-AllowHttp','-NoStart']),/unprivileged writes/);
      fs.rmSync(install,{recursive:true,force:true});
      runPowerShell(['-File',path.resolve('.tmp/windows-runner/install-provider.ps1'),'-Bundle',path.resolve('.tmp/windows-runner'),'-RunnerImage',image,'-Server',`http://${gateway}:${port}`,'-Name','windows-pc-smoke','-RegistrationTokenFile',tokenFile,'-Directory',install,'-TaskName',taskName,'-AllowHttp','-NoStart']);
      taskInstalled=true;
      const metadata=JSON.parse(runPowerShell(['-Command',`$task=Get-ScheduledTask -TaskName ${quote(taskName)}; [pscustomobject]@{user=$task.Principal.UserId; arguments=$task.Actions.Arguments; executionLimit=$task.Settings.ExecutionTimeLimit; restart=$task.Settings.RestartCount; permissions=@((Get-Acl -LiteralPath ${quote(install)}).Access | ForEach-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value})} | ConvertTo-Json -Compress`]));
      assert.ok(['SYSTEM','S-1-5-18'].includes(metadata.user),JSON.stringify(metadata));
      assert.equal(metadata.executionLimit,'PT0S');assert.equal(metadata.restart,999);
      assert.ok(!metadata.arguments.includes(registration));
      assert.deepEqual(new Set(metadata.permissions),new Set(['S-1-5-18','S-1-5-32-544']));
      runPowerShell(['-Command',`Start-ScheduledTask -TaskName ${quote(taskName)}`]);
    } else {
      worker=spawn(binary,['worker','--bootstrap-file',bootstrap,'--workspace-root',path.join(root,'workspace')],{env:{...process.env,MOONHUB_PROVIDER_TOKEN:'controller-only-sentinel',AWS_SECRET_ACCESS_KEY:'controller-only-sentinel'},stdio:['ignore','pipe','pipe']});
      worker.stdout.on('data',chunk=>{output+=chunk;process.stdout.write(chunk);}); worker.stderr.on('data',chunk=>{output+=chunk;process.stderr.write(chunk);});
      closed=new Promise((resolve,reject)=>{worker.once('error',reject);worker.once('close',code=>{exited=true;exitCode=code;resolve();});});
    }
    for(let i=0;i<1800 && !drained && !exited && !failure;i++) {
      await delay(500);
      const cancelled=attempts.get('3');
      if(cancelled && !cancelled.conclusion && Date.now()-cancelled.started>90000) {
        throw Error('Cancellation stalled: '+JSON.stringify({lastOperation:cancelled.lastOperation,logs:cancelled.logs.slice(-8000),execution:cancelled.execution})+'\n'+output);
      }
    }
    if(failure) throw failure;
    if(standalone && fs.existsSync(path.join(install,'provider.log'))) output+=fs.readFileSync(path.join(install,'provider.log'),'utf8');
    assert.ok(drained,`Worker did not drain; claims=${claims}, completed=${completed}\n${output}`);
    if(standalone) {
      assert.ok(providerToken && workerKey,'provider enrollment did not register a worker');
      const controller=path.join(install,'controller');
      const binding=fs.readFileSync(path.join(controller,'registered.json'),'utf8');
      const savedToken=fs.readFileSync(path.join(controller,'provider-token'),'utf8');
      runPowerShell(['-Command',`Stop-ScheduledTask -TaskName ${quote(taskName)}; for($i=0;$i -lt 50 -and (Get-ScheduledTask -TaskName ${quote(taskName)}).State -eq 'Running';$i++){Start-Sleep -Milliseconds 100}`]);
      assert.throws(()=>runPowerShell(['-File',path.resolve('.tmp/windows-runner/install-provider.ps1'),'-Bundle',path.resolve('.tmp/windows-runner'),'-RunnerImage',image,'-Server',`http://${gateway}:${port}`,'-Name','different-provider','-Directory',install,'-TaskName',taskName,'-AllowHttp','-NoStart']),/another provider/);
      // Reinstall without a registration credential: the private identity must survive.
      fs.rmSync(path.join(install,'registration-token'));
      runPowerShell(['-File',path.resolve('.tmp/windows-runner/install-provider.ps1'),'-Bundle',path.resolve('.tmp/windows-runner'),'-RunnerImage',image,'-Server',`http://${gateway}:${port}`,'-Name','windows-pc-smoke','-Directory',install,'-TaskName',taskName,'-AllowHttp','-NoStart']);
      assert.equal(fs.readFileSync(path.join(controller,'registered.json'),'utf8'),binding);
      assert.equal(fs.readFileSync(path.join(controller,'provider-token'),'utf8'),savedToken);
      const firstWorker=workerKey,previousDrains=drainCount;
      runPowerShell(['-Command',`Start-ScheduledTask -TaskName ${quote(taskName)}`]);
      for(let i=0;i<180 && !(workerKey!==firstWorker && drainCount>previousDrains) && !failure;i++)await delay(500);
      if(failure)throw failure;
      assert.notEqual(workerKey,firstWorker,'reinstalled provider did not enroll a fresh worker');
      assert.ok(drainCount>previousDrains,'restarted worker did not complete its drain');
      assert.equal(fs.readFileSync(path.join(controller,'provider-token'),'utf8'),savedToken);
      runPowerShell(['-Command',`Stop-ScheduledTask -TaskName ${quote(taskName)}`]);
    } else {
    await Promise.race([closed,delay(10000).then(()=>{throw Error('Drained worker did not exit');})]);
    assert.equal(exitCode,0,output);
    }
    assert.equal(claims,3);assert.equal(completed,3);assert.equal(readyAfterCleanup,3);
    assert.equal(docker(['ps','-aq','--filter','name=^moonhub-pipeline-']), '');
    assert.equal(docker(['volume','ls','-q','--filter','label=io.moonhub.pipeline.workspace=1']), '');
    console.log(`Windows ${standalone?'standalone provider':'ASG worker'} container smoke passed: same worker, fresh volumes, PowerShell, Bash, Node20 action + post, cancellation, cleanup before ready, drain.`);
  } finally {
    const owned=docker(['ps','-aq','--filter','name=^moonhub-pipeline-']).split(/\s+/).filter(Boolean);
    for(const container of owned) {
      try {console.log('Remaining container '+container+'\n'+docker(['top',container]));console.log(docker(['logs',container]));} catch {}
    }
    if(worker) worker.kill('SIGKILL');
    if(taskInstalled) {
      try {runPowerShell(['-Command',`Stop-ScheduledTask -TaskName ${quote(taskName)} -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName ${quote(taskName)} -Confirm:$false`]);}catch{}
    }
    if(fs.existsSync(install)) fs.rmSync(install,{recursive:true,force:true});
    const containers=docker(['ps','-aq','--filter','name=^moonhub-pipeline-']).split(/\s+/).filter(Boolean);
    if(containers.length) docker(['rm','-f',...containers]);
    const volumes=docker(['volume','ls','-q','--filter','label=io.moonhub.pipeline.workspace=1']).split(/\s+/).filter(Boolean);
    if(volumes.length) docker(['volume','rm',...volumes]);
    ps(`Remove-NetFirewallRule -Name '${rule}' -ErrorAction SilentlyContinue`);
    server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
    fs.rmSync(root,{recursive:true,force:true});
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
