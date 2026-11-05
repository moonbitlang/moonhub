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
async function scenario(cleanupFails) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub Windows preflight '));
  const stateFile = path.join(root, 'state.json');
  fs.writeFileSync(stateFile, JSON.stringify({runs:0,containers:[]}));
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
  assert.ok(args.includes('--network'));assert.ok(args.includes('none'));assert.ok(args.includes('ContainerUser'));
  assert.ok(!args.includes('--mount'));assert.ok(args.includes('--entrypoint'));assert.ok(args.includes('cmd.exe'));
  state.runs++;state.containers.push(args[args.indexOf('--name')+1]);save();process.exit(1);
} else if(command==='rm') {if(${JSON.stringify(cleanupFails)}) process.exit(1);state.containers=[];save();}
else if(command==='ps') console.log(state.containers.join('\\n'));
else if(command==='volume') {assert.equal(args[0],'ls');}
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
      if(body.state==='ready')ready++;
      if(body.state==='failed')failed++;
      res.writeHead(200,{'Content-Type':'application/json',Connection:'close'});
      res.end(JSON.stringify({version:1,provider_id:'1',worker_id:'1',paused:false,draining:false,config_revision:'1',config:{runner_image:'fixture:windows',cpus:'1',memory_mib:'2048'}}));
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
    assert.ok(exited,output);await closed;assert.notEqual(code,0,output);
    assert.equal(ready,0);assert.equal(claims,0);assert.equal(failed,1);
    const state=JSON.parse(fs.readFileSync(stateFile));
    assert.equal(state.runs,1);assert.equal(state.containers.length,cleanupFails?1:0);
    console.log(`Windows 11 preflight failure${cleanupFails?' with uncertain cleanup':''}: no ready/claims, hyperv used, worker stopped.`);
  }finally{
    worker.kill('SIGKILL');await closed;
    server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(root,{recursive:true,force:true});
  }
}
(async()=>{assert.equal(process.platform,'win32');await scenario(false);await scenario(true);})().catch(error=>{console.error(error);process.exitCode=1;});
