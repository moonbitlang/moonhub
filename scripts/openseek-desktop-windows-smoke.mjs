// Opt-in controller for the native HTTP fixture in desktop_windows_wbtest.mbt.
// The only local transport adapter supplies a pinned Git bundle. Cache, Artifact,
// claims, leases and completion use the real coordinator and production routes.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import {execFileSync, spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {createRequire} from 'node:module';
import {forwardAcceptanceRequest} from './acceptance-http-proxy.mjs';
const {parse} = createRequire(new URL('../runner/actions/package.json',import.meta.url))('yaml');
const config = JSON.parse(await fs.readFile(process.argv[2],'utf8'));
assert.equal(process.platform,'win32'); assert.equal(process.arch,'x64');
const sha = '62a6fba1dccf92c98d4b3c26f5dcf12a5788a8b5';
const image = process.env.MOONHUB_WINDOWS_BUILD_IMAGE || 'moonhub:build-windows-2025';
const docker = (...args) => execFileSync('docker.exe',['--host','npipe:////./pipe/docker_engine',...args],{encoding:'utf8',timeout:120000,maxBuffer:4194304}).trim();
const powershell = command => execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',"$ErrorActionPreference='Stop';"+command],{encoding:'utf8',timeout:30000});
const git = (...args) => execFileSync('git',['-c','core.hooksPath=NUL','--git-dir',config.source,...args],{maxBuffer:67108864});
const fixture = await fs.readFile(new URL('../pipeline/workflow/fixtures/openseek-desktop-windows.yml',import.meta.url),'utf8');
assert.equal(git('show',sha+':.github/workflows/desktop-windows.yml').toString().replaceAll('\r\n','\n'),fixture.replaceAll('\r\n','\n'));
assert.equal(git('rev-parse','refs/heads/main').toString().trim(),sha);
assert.equal(git('rev-list','--count','refs/heads/main').toString().trim(),'1');
assert.match(docker('image','inspect','--format','{{.Os}}/{{.Architecture}}/{{.OsVersion}}',image),/^windows\/amd64\/10\.0\.26100\./);
const job = parse(fixture).jobs['desktop-package-windows'];
const root = await fs.mkdtemp(path.join(os.tmpdir(),'moonhub Desktop Windows '));
const bundleFile = path.join(root,'source.bundle');
git('bundle','create',bundleFile,'refs/heads/main');
const bundle = await fs.readFile(bundleFile); assert.ok(bundle.length <= 67108864);
const gateway = JSON.parse(docker('network','inspect','nat'))[0].IPAM.Config.find(value=>value.Gateway)?.Gateway;
assert.match(gateway,/^[\d.]+$/);
const backend = new URL(config.server), attempts = new Map();
const rule = 'MoonHubDesktopCI-'+randomBytes(8).toString('hex');
let failure, requests=0, downloads=0;
const server = http.createServer(async (req,res) => {
  try {
    const source = /^\/-\/runner-api\/v1\/attempts\/(\d+)\/source-bundle$/.exec(req.url);
    if(source) {
      assert.equal(req.method,'GET');
      assert.equal(req.headers.authorization,'Bearer '+attempts.get(source[1]));
      downloads++;
      res.writeHead(200,{'Content-Length':bundle.length,'Content-Type':'application/x-git-bundle','Cache-Control':'no-store'});
      res.end(bundle); return;
    }
    assert.ok(req.url.startsWith('/-/runner-api/v1/') || req.url.startsWith('/twirp/github.actions.results.api.v1.') || req.url.startsWith('/-/artifact-blobs/'));
    let body;
    if(req.url.endsWith('/logs')) {
      const chunks=[]; let size=0;
      for await(const chunk of req) {size+=chunk.length;assert.ok(size<=65536);chunks.push(chunk);}
      body=Buffer.concat(chunks);
      const log=JSON.parse(body);
      assert.ok(!log.text.includes(config.token));
      assert.ok([...attempts.values()].every(token=>!log.text.includes(token)));
      process.stdout.write(log.text);
    }
    requests++;
    forwardAcceptanceRequest(req,res,backend,{body,onError:error=>{failure=error;}});
  } catch(error) {failure=error;if(!res.headersSent)res.writeHead(500);res.end('acceptance transport failed');}
});
await new Promise(resolve=>server.listen(0,'0.0.0.0',resolve));
const origin='http://'+gateway+':'+server.address().port;
async function execute(index) {
  console.log('DESKTOP_ACCEPTANCE_JOB:'+index+':claim');
  const response=await fetch(config.server+'/-/acceptance/next',{method:'POST',headers:{Authorization:'Bearer '+config.token}});
  assert.equal(response.status,200);
  const {assignment,token}=await response.json();
  assert.equal(assignment.commit_sha,sha);assert.equal(assignment.version,11);
  attempts.set(assignment.attempt_id,token);
  if(index===0) {
    assert.equal(assignment.job.id,'desktop-package-windows');
    assert.equal(assignment.job.steps.length,job.steps.length);
    for(const [i,step] of job.steps.entries()) {
      assert.equal(assignment.job.steps[i].uses,step.uses || '');
      assert.equal(assignment.job.steps[i].run,step.run || '');
      if(step.run)assert.equal(assignment.job.steps[i].shell,'pwsh');
    }
  } else assert.equal(assignment.job.id,'verify');
  const suffix=randomBytes(8).toString('hex'),name='moonhub-desktop-ci-'+suffix;
  const control=path.join(root,'control-'+index);await fs.mkdir(control);
  await fs.writeFile(path.join(control,'assignment.json'),JSON.stringify(assignment));
  execFileSync('icacls.exe',[control,'/grant','*S-1-5-32-545:(OI)(CI)RX','/T'],{stdio:'inherit'});
  let child,closed,timer;
  try {
    docker('volume','create',name);
    docker('run','--rm','--network','none','--isolation','process','--user','ContainerAdministrator','--mount','type=volume,src='+name+',dst=C:\\workspace','--entrypoint','C:\\Windows\\System32\\icacls.exe',image,'C:\\workspace','/grant','*S-1-5-32-545:(OI)(CI)M');
    child=spawn('docker.exe',['--host','npipe:////./pipe/docker_engine','run','--rm','--interactive','--name',name,'--isolation','process','--user','ContainerUser','--memory','6g','--cpu-count','2','--mount','type=volume,src='+name+',dst=C:\\workspace','--mount','type=bind,src='+control+',dst=C:\\control,readonly',image,'--server',origin,'--assignment','C:/control/assignment.json','--allow-http'],{stdio:['pipe','pipe','inherit']});
    let output='';child.stdout.on('data',chunk=>{output+=chunk;});
    closed=new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
    child.stdin.end(token+'\n');
    timer=setTimeout(()=>child.kill('SIGKILL'),assignment.job.timeout_minutes*60000+90000);
    const code=await closed;clearTimeout(timer);
    console.log(output.trim());if(failure)throw failure;
    assert.equal(code,0);const report=JSON.parse(output.trim());
    assert.equal(report.conclusion,'success');assert.equal(report.reported,true);
    assert.ok(report.steps.every(step=>step.state==='success'));
    const gitconfig=docker('run','--rm','--network','none','--isolation','process','--user','ContainerUser','--mount','type=volume,src='+name+',dst=C:\\workspace','--entrypoint','C:\\moonhub\\pwsh\\pwsh.exe',image,'-NoProfile','-Command','Get-Content C:/workspace/repository/.git/config -Raw');
    assert.doesNotMatch(gitconfig,/extraheader/i);
    console.log('DESKTOP_ACCEPTANCE_JOB:'+index+':success');
  } finally {
    clearTimeout(timer);if(child)child.kill('SIGKILL');try{docker('rm','--force',name);}catch{}if(closed)await closed.catch(()=>{});
    docker('volume','rm',name);
    assert.equal(docker('volume','ls','-q','--filter','name=^'+name+'$'),'');
    assert.equal(docker('ps','-aq','--filter','name=^'+name+'$'),'');
  }
}
try {
  powershell("New-NetFirewallRule -Name '"+rule+"' -DisplayName '"+rule+"' -Direction Inbound -Action Allow -Protocol TCP -LocalPort "+server.address().port+" | Out-Null");
  await execute(0);await execute(1);
  assert.equal(downloads,2);assert.ok(requests>0);
  console.log('OPENSEEK_DESKTOP_WINDOWS_OK:'+sha);
} finally {
  try{powershell("Remove-NetFirewallRule -Name '"+rule+"' -ErrorAction SilentlyContinue");}
  finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await fs.rm(root,{recursive:true,force:true});}
}
