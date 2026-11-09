// Exercise the real native worker with a deterministic Windows 11 Docker adapter.
// Hosted Windows Server CI cannot substitute for physical Windows 11/Hyper-V.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function scenario(failureStage, cleanupFails = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub Windows preflight '));
  const stateFile = path.join(root, 'state.json');
  fs.writeFileSync(stateFile, JSON.stringify({runs:0,containers:[],volumes:[]}));
  // Node treats the first Docker subcommand as its script path. Each file is
  // resolved in the child's private cwd, without requiring a shell or fake exe.
  const adapter = `
const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const file=${JSON.stringify(stateFile)},state=JSON.parse(fs.readFileSync(file)),command=path.basename(process.argv[1]),args=process.argv.slice(2);
const save=()=>fs.writeFileSync(file,JSON.stringify(state));
if(command==='info') console.log(JSON.stringify({OSType:'windows',Architecture:'amd64',OperatingSystem:'Microsoft Windows Version 24H2 (OS Build 26100.4652)',KernelVersion:'10.0.26100.4652'}));
else if(command==='image') console.log(args.includes('{{.Os}}/{{.Architecture}}/{{.OsVersion}}')?'windows/amd64/10.0.20348.1':'sha256:fixture');
else if(command==='run') {
  assert.equal(args[args.indexOf('--isolation')+1],'hyperv');
  assert.equal(args[args.indexOf('--network')+1],'none');
  assert.equal(args[args.indexOf('--memory')+1],'2048m');
  assert.equal(args[args.indexOf('--cpu-count')+1],'1');
  const mounts=args.filter((value,index)=>args[index-1]==='--mount');
  assert.equal(mounts.length,1);assert.ok(mounts[0].startsWith('type=volume,src=moonhub-workspace-'));
  assert.ok(mounts[0].endsWith('dst=C:'+String.fromCharCode(92)+'workspace'));
  assert.ok(!args.includes('--interactive'));assert.ok(!args.some(value=>value.includes('assignment.json')||value.includes('token')));
  const initializing=args.includes('ContainerAdministrator');
  if(initializing) {
    assert.ok(state.runs===0||state.runs===2,'volume initialization must precede readiness');
    assert.equal(args[args.indexOf('--entrypoint')+1],['C:','Windows','System32','icacls.exe'].join(String.fromCharCode(92)));
    assert.deepEqual(args.slice(-3),['C:'+String.fromCharCode(92)+'workspace','/grant','*S-1-5-32-545:(OI)(CI)M']);
  } else {
    assert.ok(args.includes('ContainerUser'));assert.ok(args.includes('cmd.exe'));
    assert.equal(state.runs,1,'unprivileged probe ran before volume initialization');
    assert.match(args.at(-1),/mkdir.*echo ready.*type.*rmdir/);
  }
  state.runs++;const failed=${JSON.stringify(failureStage)}===(initializing?'initialize':'probe');
  if(failed)state.containers.push(args[args.indexOf('--name')+1]);save();process.exit(failed?1:0);
} else if(command==='rm') {if(${JSON.stringify(cleanupFails)}) process.exit(1);state.containers=[];save();}
else if(command==='ps') console.log(state.containers.join('\\n'));
else if(command==='volume') {
  if(args[0]==='create'){const name=args.at(-1);state.volumes.push(name);save();console.log(name);}
  else if(args[0]==='rm'){assert.equal(state.containers.length,0,'volume removed while initializer or probe remained');state.volumes=state.volumes.filter(name=>name!==args[1]);save();}
  else {assert.equal(args[0],'ls');console.log(state.volumes.join('\\n'));}
}
else throw Error('Unexpected Docker command '+command);
`;
  for (const command of ['info','image','run','rm','ps','volume']) fs.writeFileSync(path.join(root, command), adapter);
  let ready=0,claims=0,failed=0,failure;
  const token=crypto.randomBytes(32).toString('hex');
  const server=http.createServer(async(req,res)=>{
    try {
      assert.equal(req.headers.authorization,'Bearer '+token);
      let raw='';for await(const chunk of req) raw+=chunk;
      const body=JSON.parse(raw);
      if(req.url.endsWith('/claims')) {claims++;throw Error('Claimed before successful container preflight');}
      assert.ok(req.url.endsWith('/workers/sync'));
      if(body.state==='ready'){
        ready++;const workspace=JSON.parse(fs.readFileSync(stateFile));
        assert.equal(workspace.volumes.length,1,'ready requires exactly one prepared workspace');
        assert.ok(workspace.volumes[0].startsWith('moonhub-workspace-prepared-'));
        assert.equal(workspace.runs,3,'ready preceded workspace initialization');
      }
      if(body.state==='failed')failed++;
      res.writeHead(200,{'Content-Type':'application/json',Connection:'close'});
      res.end(JSON.stringify({version:1,provider_id:'1',worker_id:'1',paused:false,draining:body.state==='ready',config_revision:'1',config:{runner_image:'fixture:windows',cpus:'1',memory_mib:'2048'}}));
    }catch(error){failure=error;res.writeHead(500);res.end('{}');}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const bootstrap=path.join(root,'bootstrap.json');
  fs.writeFileSync(bootstrap,JSON.stringify({server:`http://127.0.0.1:${server.address().port}`,token,allow_http:true,runner_image:'fixture:windows',runner_os:'windows'}));
  const worker=spawn(path.resolve('.tmp/windows-runner/bin/moonhub-runner.exe'),['worker','--bootstrap-file',bootstrap,'--workspace-root',path.join(root,'workspace'),'--docker',process.execPath],{cwd:root,stdio:['ignore','pipe','pipe']});
  let output='',code,exited=false;
  worker.stdout.on('data',chunk=>output+=chunk);worker.stderr.on('data',chunk=>output+=chunk);
  const closed=new Promise((resolve,reject)=>{worker.once('error',reject);worker.once('close',value=>{code=value;exited=true;resolve();});});
  try {
    for(let i=0;i<200&&!exited&&!failure;i++)await delay(100);
    if(failure)throw failure;
    assert.ok(exited,output);await closed;assert.equal(code===0,!failureStage&&!cleanupFails,output);
    if(failureStage||cleanupFails)assert.equal(ready,0);else assert.ok(ready>=1);
    assert.equal(claims,0);assert.equal(failed,failureStage||cleanupFails?1:0);
    const state=JSON.parse(fs.readFileSync(stateFile));
    assert.equal(state.runs,failureStage==='initialize'?1:failureStage==='probe'?2:3);assert.equal(state.containers.length,cleanupFails?1:0);
    assert.equal(state.volumes.length,cleanupFails?1:0);
    console.log(`Windows 11 workspace preflight ${failureStage||'success'}${cleanupFails?' with uncertain cleanup':''}: isolation, ACL initialization and readiness verified.`);
  }finally{
    worker.kill('SIGKILL');await closed;
    server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(root,{recursive:true,force:true});
  }
}
(async()=>{assert.equal(process.platform,'win32');await scenario('initialize');await scenario('probe');await scenario('probe',true);await scenario(null);})().catch(error=>{console.error(error);process.exitCode=1;});
