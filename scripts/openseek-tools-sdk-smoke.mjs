// Opt-in acceptance: the real native runner executes the unchanged upstream job
// over its HTTP protocol inside the Ubuntu 24.04 x64 container.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import {execFileSync, spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {createRequire} from 'node:module';
const require = createRequire(new URL('../runner/actions/package.json',import.meta.url));
const {parse} = require('yaml');
const sha = '9e8b15a59b40b62b018e53b4b85a3bea971e1acf';
const source = process.argv[2];
const editor = process.argv[3] === 'editor-linux';
const fixtureName = editor ? 'openseek-editor.yml' : 'openseek-tools-sdk.yml';
const upstreamName = editor ? 'editor.yml' : 'tools-sdk.yml';
assert.ok(source,'pass the immutable bare openseek repository path');
assert.equal(process.platform,'linux'); assert.equal(process.arch,'x64');
const release = await fs.readFile('/etc/os-release','utf8');
assert.match(release,/^ID=ubuntu$/m); assert.match(release,/^VERSION_ID="24.04"$/m);
const fixture = await fs.readFile(new URL('../pipeline/workflow/fixtures/'+fixtureName,import.meta.url),'utf8');
const git = (...args) => execFileSync('git',['-c','safe.directory='+source,'-c','core.hooksPath=/dev/null','--git-dir',source,...args],{maxBuffer:64*1024*1024});
assert.equal(git('show',sha+':.github/workflows/'+upstreamName).toString().trimEnd(),fixture.trimEnd());
const workflow=parse(fixture), job=editor ? workflow.jobs['moon-gates'] : workflow.jobs.check;
if (editor) assert.deepEqual(job.strategy.matrix.os,['ubuntu-24.04','macos-latest']);
else assert.equal(job['runs-on'],'ubuntu-24.04');
assert.deepEqual(job.permissions,{contents:'read'});
const bundle=git('bundle','create','-','refs/heads/main');
const root=await fs.mkdtemp(path.join(os.tmpdir(),'moonhub-tools-sdk-'));
const workspace=path.join(root,'workspace'); await fs.mkdir(workspace);
const token=randomBytes(32).toString('hex'), now=Date.now();
const steps=job.steps.map((step,index)=> ({id:step.id || `step_${index+1}`,name:step.name || step.uses || step.run,remote:typeof step.uses==='string',uses:step.uses || '',run:step.run || '',shell:step.shell || '',working_directory:step.uses ? '.' : step['working-directory'] || job.defaults?.run?.['working-directory'] || '.',env:step.env || {},env_overrides:Object.keys(step.env || {}),inputs:Object.fromEntries(Object.entries(step.with || {}).map(([key,value])=>[key,String(value)])),secret_env:{},templates:{},moonbit_version:'',timeout_minutes:step['timeout-minutes'] || 0}));
const assignment={version:editor?6:5,attempt_id:'1',run_id:'1',job_id:'1',repository:'moonbitlang/openseek',commit_sha:sha,lease_until_ms:String(now+60000),server_time_ms:String(now),state:'leased',job:{context:{event_name:'push',ref:'refs/heads/main',workflow:workflow.name},contents_read:true,matrix:editor?{os:'ubuntu-24.04'}:{},strategy:editor?{'job-index':0,'job-total':2,'fail-fast':false,'max-parallel':256}:{},id:editor?'moon-gates':'check',name:editor?'moon (stable, ubuntu-24.04)':'check',runs_on:['self-hosted','linux','x64','ubuntu-24.04'],timeout_minutes:job['timeout-minutes'] || 30,steps}};
let execution='', sequence=0, conclusion='', downloads=0, handlerError;
const states=new Map();
const server=http.createServer(async (req,res)=> {
  try {
    assert.equal(req.headers.authorization,'Bearer '+token);
    const operation=req.url.split('/').at(-1);
    if(req.method==='GET' && operation==='source-bundle') {
      assert.ok(execution); downloads++; res.writeHead(200,{'Content-Length':bundle.length,'Content-Type':'application/x-git-bundle','Cache-Control':'no-store'}); res.end(bundle); return;
    }
    assert.equal(req.method,'POST');
    let raw=''; for await(const chunk of req) {raw+=chunk; assert.ok(raw.length<2*1024*1024);}
    const body=JSON.parse(raw);
    if(operation==='artifact-runtime') {
      assert.equal(body.version,1); assert.equal(body.execution_id,execution); assert.ok(execution);
      assert.equal(body.origin,`http://127.0.0.1:${server.address().port}`);
      res.writeHead(200,{'Content-Type':'application/json'});
      res.end(JSON.stringify({token:randomBytes(32).toString('hex'),results_url:body.origin,expires_ms:String(Date.now()+3600000)})); return;
    }
    if(operation==='start') execution=body.execution_id;
    else if(operation==='logs') {
      assert.equal(body.sequence,String(sequence+1)); sequence++; process.stdout.write(body.text);
    } else if(operation==='steps') {
      assert.ok(steps.some(step=> step.id===body.step_id)); states.set(body.step_id,body.state);
      console.log(`TOOLS_SDK_STEP:${body.step_id}:${body.state}`);
    } else if(operation==='complete') {conclusion=body.conclusion; assert.equal(body.last_log_sequence,String(sequence));}
    else assert.equal(operation,'heartbeat');
    const current=Date.now();
    res.writeHead(200,{'Content-Type':'application/json'});
    res.end(JSON.stringify({version:1,execution_id:execution,attempt_id:'1',state:conclusion?'completed':'running',lease_until_ms:String(current+60000),server_time_ms:String(current),deadline_ms:String(now+(job['timeout-minutes'] || 30)*60000),cancel_requested:false,log_sequence:String(sequence),conclusion}));
  } catch(error) {handlerError=error; res.writeHead(500); res.end('acceptance protocol assertion failed');}
});
await new Promise(resolve=> server.listen(0,'127.0.0.1',resolve));
try {
  const filename=path.join(root,'assignment.json'); await fs.writeFile(filename,JSON.stringify(assignment),{mode:0o600});
  const child=spawn('/usr/local/bin/moonhub-runner',['execute','--server',`http://127.0.0.1:${server.address().port}`,'--assignment',filename,'--workspace',workspace,'--launcher','/usr/local/bin/moonhub-runner-step','--allow-http','--unsafe-local'],{stdio:['pipe','pipe','inherit']});
  child.stdin.end(token+'\n'); let output=''; child.stdout.on('data',chunk=> {output+=chunk;});
  const code=await new Promise((resolve,reject)=> {child.once('error',reject);child.once('exit',resolve);});
  if(handlerError) throw handlerError;
  console.log(output.trim());
  assert.equal(code,0); assert.equal(conclusion,'success'); assert.equal(downloads,1);
  const report=JSON.parse(output.trim()); assert.equal(report.reported,true);
  assert.deepEqual(steps.map(step=> states.get(step.id)),steps.map(()=> 'success'));
  assert.ok(!(await fs.readFile(path.join(workspace,'repository/.git/config'),'utf8')).includes('extraheader'),'checkout post must remove temporary authentication');
  console.log(`${editor?'OPENSEEK_EDITOR_LINUX_OK':'OPENSEEK_TOOLS_SDK_OK'}:${sha}`);
} finally {await new Promise(resolve=> server.close(resolve));await fs.rm(root,{recursive:true,force:true});}
