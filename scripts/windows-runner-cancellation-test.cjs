// Exercise MoonBit's full lease/cancellation path before the slower image build.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function scenario(cancelOn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'moonhub cancel '));
  const workspace = path.join(root,'workspace');fs.mkdirSync(workspace);
  const pidFile = path.join(workspace,'child-pid');
  const token = crypto.randomBytes(32).toString('hex');
  let execution='',sequence=0n,ready=false,cancelled=false,complete='',failure,output='',diagnostic='',lastOperation='';
  const started=Date.now();
  const server=http.createServer(async(req,res)=>{
    try {
      assert.equal(req.headers.authorization,'Bearer '+token);
      if(req.method==='GET') {res.writeHead(200,{'Content-Length':1024,Connection:'close'});res.end(Buffer.alloc(1024));return;}
      let raw='';for await(const chunk of req) raw+=chunk;
      const body=JSON.parse(raw), operation=req.url.split('/').pop();lastOperation=operation;
      if(operation==='start') execution=body.execution_id;
      if(operation==='logs') {assert.equal(BigInt(body.sequence),++sequence);if(body.text.includes('cancel-ready')) ready=true;}
      if(ready && operation===cancelOn) cancelled=true;
      if(operation==='complete') {complete=body.conclusion;assert.equal(complete,'cancelled');assert.equal(BigInt(body.last_log_sequence),sequence);}
      const now=Date.now();
      res.writeHead(200,{'Content-Type':'application/json',Connection:'close'});
      res.end(JSON.stringify({version:1,execution_id:execution,attempt_id:'1',state:complete?'completed':'running',server_time_ms:String(now),lease_until_ms:String(now+60000),deadline_ms:String(started+60000),cancel_requested:cancelled,log_sequence:String(sequence),conclusion:complete}));
    } catch(error) {failure=error;res.writeHead(500);res.end('{}');}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const now=Date.now();
  const assignment={version:1,attempt_id:'1',run_id:'1',job_id:'1',repository:'test/probe',commit_sha:'a'.repeat(40),server_time_ms:String(now),lease_until_ms:String(now+60000),state:'leased',job:{id:'build',name:'Build',runs_on:['self-hosted','windows'],timeout_minutes:1,steps:[{id:'probe',name:'Probe',run:`$child=Start-Process -FilePath $env:SMOKE_NODE -ArgumentList '-e','setInterval(()=>{},1000)' -PassThru -NoNewWindow\n[IO.File]::WriteAllText($env:SMOKE_PID, [string]$child.Id)\nWrite-Output 'cancel-ready'\nStart-Sleep -Seconds 60`,shell:'',working_directory:'.',env:{SMOKE_NODE:process.execPath,SMOKE_PID:pidFile},timeout_minutes:0}]}};
  const manifest=path.join(root,'assignment.json');fs.writeFileSync(manifest,JSON.stringify(assignment));
  const child=spawn(path.resolve('.tmp/windows-runner/bin/moonhub-runner.exe'),['execute','--server',`http://127.0.0.1:${server.address().port}`,'--assignment',manifest,'--workspace',workspace,'--launcher',path.resolve('.tmp/windows-runner/bin/moonhub-runner-step.exe'),'--allow-http','--unsafe-local'],{stdio:['pipe','pipe','pipe']});
  child.stdout.on('data',chunk=>{output+=chunk;});child.stderr.on('data',chunk=>{diagnostic+=chunk;});child.stdin.end(token+'\r\n');
  let exited=false,code;const closed=new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',value=>{exited=true;code=value;resolve();});});
  try {
    for(let i=0;i<300 && !exited && !failure;i++) await delay(100);
    if(failure) throw failure;
    assert.ok(exited,`Cancellation stalled after ${lastOperation}\n${output}\n${diagnostic}`);
    await closed;
    assert.equal(code,1,diagnostic);assert.equal(complete,'cancelled');assert.equal(JSON.parse(output.trim()).reported,true);
    const pid=Number(fs.readFileSync(pidFile,'utf8'));let alive=true;
    for(let i=0;i<50;i++) {try{process.kill(pid,0);}catch{alive=false;break;}await delay(100);}
    assert.equal(alive,false,'step descendant survived runner cancellation');
    console.log(`Windows runner cancellation via ${cancelOn}: completion reported, process tree stopped.`);
  } finally {
    child.kill('SIGKILL');await closed;
    if(fs.existsSync(pidFile)) {try{process.kill(Number(fs.readFileSync(pidFile,'utf8')),'SIGKILL');}catch{}}
    server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(root,{recursive:true,force:true});
  }
}
(async()=>{assert.equal(process.platform,'win32');await scenario('logs');await scenario('heartbeat');})().catch(error=>{console.error(error);process.exitCode=1;});
