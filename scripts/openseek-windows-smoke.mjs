// Pinned upstream job, unchanged executable steps, real isolated Windows runner.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import {execFileSync,spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {createRequire} from 'node:module';
const {parse}=createRequire(new URL('../runner/actions/package.json',import.meta.url))('yaml');
const sha='62a6fba1dccf92c98d4b3c26f5dcf12a5788a8b5',source=path.resolve(process.argv[2] || '.tmp/openseek-source.git');
const image=process.env.MOONHUB_WINDOWS_BUILD_IMAGE || 'moonhub:build-windows-2025';
const docker=(...args)=>execFileSync('docker.exe',['--host','npipe:////./pipe/docker_engine',...args],{encoding:'utf8',timeout:120000,maxBuffer:4194304}).trim();
const ps=s=>execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',s],{encoding:'utf8',timeout:30000});
const git=(...args)=>execFileSync('git',['-c','core.hooksPath=NUL','--git-dir',source,...args],{maxBuffer:67108864});
assert.equal(process.platform,'win32');assert.equal(process.arch,'x64');
assert.match(docker('image','inspect','--format','{{.Os}}/{{.Architecture}}/{{.OsVersion}}',image),/^windows\/amd64\/10\.0\.26100\./);
const fixture=await fs.readFile(new URL('../pipeline/workflow/fixtures/openseek-ci-windows.yml',import.meta.url),'utf8');
assert.equal(git('show',sha+':.github/workflows/ci.yml').toString().replaceAll('\r\n','\n'),fixture.replaceAll('\r\n','\n'));
assert.equal(git('rev-parse','refs/heads/main').toString().trim(),sha);
assert.equal(git('rev-list','--count','refs/heads/main').toString().trim(),'1');
const workflow=parse(fixture),job=workflow.jobs['tui-windows'];
assert.equal(job['runs-on'],'windows-latest');assert.deepEqual(job.permissions,{contents:'read'});assert.equal(job.steps.length,6);
const root=await fs.mkdtemp(path.join(os.tmpdir(),'moonhub Windows CI ')),control=path.join(root,'control');await fs.mkdir(control);
const suffix=randomBytes(8).toString('hex'),volume='moonhub-windows-ci-'+suffix,container=volume,rule='MoonHubWindowsCI-'+suffix;
const bundleFile=path.join(root,'source.bundle');git('bundle','create',bundleFile,'refs/heads/main');const bundle=await fs.readFile(bundleFile);assert.ok(bundle.length<=67108864);
const gateway=JSON.parse(docker('network','inspect','nat'))[0].IPAM.Config.find(v=>v.Gateway)?.Gateway;assert.match(gateway,/^[\d.]+$/);
const token=randomBytes(32).toString('hex'),now=Date.now();
const steps=job.steps.map((s,i)=>({id:s.id || 'step_'+(i+1),name:s.name || s.uses || s.run,remote:!!s.uses,uses:s.uses || '',run:s.run || '',shell:s.shell || '',working_directory:s['working-directory'] || '.',env:s.env || {},env_overrides:Object.keys(s.env || {}),inputs:Object.fromEntries(Object.entries(s.with || {}).map(([k,v])=>[k,String(v)])),secret_env:{},templates:{},moonbit_version:'',timeout_minutes:s['timeout-minutes'] || 0}));
const assignment={version:11,attempt_id:'1',run_id:'1',job_id:'1',repository:'moonbitlang/openseek',commit_sha:sha,lease_until_ms:String(now+60000),server_time_ms:String(now),state:'leased',job:{variables:{},dispatch_inputs:{},event:{},outputs:{},needs:{},context:{event_name:'pull_request',ref:'refs/pull/1/merge',workflow:workflow.name,actor:'acceptance'},contents_read:true,id_token_write:false,matrix:{},strategy:{},id:'tui-windows',name:job.name,runs_on:['self-hosted','windows','x64','windows-2025'],timeout_minutes:job['timeout-minutes'] || 360,steps}};
let execution='',sequence=0,conclusion='',downloads=0,failure;const states=new Map(),grants=[];
const server=http.createServer(async(req,res)=>{
 try{
  assert.equal(req.headers.authorization,'Bearer '+token);const op=req.url.split('/').at(-1);
  if(req.method==='GET' && op==='source-bundle'){assert.ok(execution);downloads++;res.writeHead(200,{'Content-Length':bundle.length,'Content-Type':'application/x-git-bundle'});res.end(bundle);return;}
  assert.equal(req.method,'POST');let raw='';for await(const chunk of req){raw+=chunk;assert.ok(raw.length<2097152);}const body=JSON.parse(raw);
  if(op==='artifact-runtime'){
   assert.equal(body.execution_id,execution);assert.ok(execution);assert.equal(body.origin,'http://'+gateway+':'+server.address().port);
   const grant=randomBytes(32).toString('hex');grants.push(grant);res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({token:grant,results_url:body.origin,expires_ms:String(Date.now()+3600000)}));return;
  }
  if(op==='start'){assert.ok(!execution);execution=body.execution_id;}
  else if(op==='logs'){assert.equal(body.sequence,String(++sequence));assert.ok(!body.text.includes(token));assert.ok(grants.every(v=>!body.text.includes(v)));process.stdout.write(body.text);}
  else if(op==='steps'){assert.ok(steps.some(s=>s.id===body.step_id));states.set(body.step_id,body.state);console.log('WINDOWS_CI_STEP:'+body.step_id+':'+body.state);}
  else if(op==='complete'){conclusion=body.conclusion;assert.equal(body.last_log_sequence,String(sequence));}
  else assert.equal(op,'heartbeat');
  res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({version:1,execution_id:execution,attempt_id:'1',state:conclusion?'completed':'running',lease_until_ms:String(Date.now()+60000),server_time_ms:String(Date.now()),deadline_ms:String(now+assignment.job.timeout_minutes*60000),cancel_requested:false,log_sequence:String(sequence),conclusion}));
 }catch(e){failure=e;res.writeHead(500);res.end('acceptance rejected request');}
});
await new Promise(r=>server.listen(0,'0.0.0.0',r));let child,closed,timer;
try{
 await fs.writeFile(path.join(control,'assignment.json'),JSON.stringify(assignment));execFileSync('icacls.exe',[control,'/grant','*S-1-5-32-545:(OI)(CI)RX','/T'],{stdio:'inherit'});
 ps("New-NetFirewallRule -Name '"+rule+"' -DisplayName '"+rule+"' -Direction Inbound -Action Allow -Protocol TCP -LocalPort "+server.address().port+" | Out-Null");
 docker('volume','create',volume);
 docker('run','--rm','--network','none','--isolation','process','--user','ContainerAdministrator','--mount','type=volume,src='+volume+',dst=C:\\workspace','--entrypoint','C:\\Windows\\System32\\icacls.exe',image,'C:\\workspace','/grant','*S-1-5-32-545:(OI)(CI)M');
 child=spawn('docker.exe',['--host','npipe:////./pipe/docker_engine','run','--rm','--interactive','--name',container,'--isolation','process','--user','ContainerUser','--memory','6g','--cpu-count','2','--mount','type=volume,src='+volume+',dst=C:\\workspace','--mount','type=bind,src='+control+',dst=C:\\control,readonly',image,'--server','http://'+gateway+':'+server.address().port,'--assignment','C:/control/assignment.json','--allow-http'],{stdio:['pipe','pipe','inherit']});
 child.stdin.end(token+'\n');let output='';child.stdout.on('data',chunk=>{output+=chunk;});closed=new Promise((r,j)=>{child.once('error',j);child.once('close',r);});
 timer=setTimeout(()=>child.kill('SIGKILL'),assignment.job.timeout_minutes*60000+90000);const code=await closed;clearTimeout(timer);if(failure)throw failure;
 console.log(output.trim());assert.equal(code,0);assert.equal(conclusion,'success');assert.equal(downloads,1);assert.equal(JSON.parse(output.trim()).reported,true);assert.deepEqual(steps.map(s=>states.get(s.id)),steps.map(()=> 'success'));
 const config=docker('run','--rm','--network','none','--isolation','process','--user','ContainerUser','--mount','type=volume,src='+volume+',dst=C:\\workspace','--entrypoint','C:\\moonhub\\pwsh\\pwsh.exe',image,'-NoProfile','-Command','Get-Content C:/workspace/repository/.git/config -Raw');
 assert.ok(!/extraheader/i.test(config),'checkout post retained temporary authorization');console.log('OPENSEEK_WINDOWS_TUI_OK:'+sha);
}finally{
 try {
  clearTimeout(timer);if(child)child.kill('SIGKILL');try{docker('rm','--force',container);}catch{}if(closed)await closed.catch(()=>{});
  docker('volume','rm',volume);assert.equal(docker('volume','ls','-q','--filter','name=^'+volume+'$'),'');assert.equal(docker('ps','-aq','--filter','name=^'+container+'$'),'');
 } finally {
  try{ps("Remove-NetFirewallRule -Name '"+rule+"' -ErrorAction SilentlyContinue");}finally{server.closeAllConnections();await new Promise(r=>server.close(r));await fs.rm(root,{recursive:true,force:true});}
 }
}
