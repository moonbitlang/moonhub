// Exercise V13 probes in the ordinary read-only Docker profile on one reusable
// host. No privileged flag, host Docker socket or cloud resources are required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn, execFileSync} = require('node:child_process');
const image = process.env.MOONHUB_EXECUTION_IMAGE || 'moonhub-runner:adaptive-dev';
const docker = args => execFileSync('docker', args, {encoding:'utf8',timeout:30000});
async function scenario(script, capability, successful = false) {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'moonhub-route-smoke-'));
  const name='moonhub-route-smoke-'+crypto.randomBytes(8).toString('hex');
  const token=crypto.randomBytes(32).toString('hex'), logs=[];
  let sequence=0, execution='', completion, failure, timer;
  const server=http.createServer(async(req,res) => {
    try {
      assert.equal(req.headers.authorization,'Bearer '+token);
      let source='';for await(const chunk of req){source+=chunk;assert.ok(source.length<=65536);}
      const body=JSON.parse(source),operation=req.url.split('/').at(-1);
      if(operation==='start') execution=body.execution_id;
      else if(operation==='logs'){assert.equal(body.sequence,String(++sequence));logs.push(body.text);assert.ok(!body.text.includes(token));}
      else if(operation==='complete'){completion=body;assert.equal(body.last_log_sequence,String(sequence));}
      else assert.ok(['steps','heartbeat'].includes(operation));
      const now=Date.now();res.writeHead(200,{'Content-Type':'application/json'});
      res.end(JSON.stringify({version:1,execution_id:execution,attempt_id:'1',state:completion?'completed':'running',server_time_ms:String(now),lease_until_ms:String(now+60000),deadline_ms:String(started+60000),cancel_requested:false,log_sequence:String(sequence),conclusion:completion?.conclusion || ''}));
    } catch(error){failure=error;res.writeHead(500);res.end('fixture rejected');}
  });
  const started=Date.now();await new Promise(resolve=>server.listen(0,'0.0.0.0',resolve));
  const assignment={version:13,attempt_id:'1',run_id:'1',job_id:'1',repository:'test/route',commit_sha:'a'.repeat(40),lease_until_ms:String(started+60000),server_time_ms:String(started),state:'leased',
    execution:{environment:'ubuntu',environment_version:'v1',profile:'restricted',probe_capabilities:true},
    job:{id:'probe',name:'Probe',contents_read:false,runs_on:['self-hosted','linux'],timeout_minutes:1,steps:[{id:'probe',name:'Probe',run:script,shell:'bash',working_directory:'.',env:{},timeout_minutes:0}]}};
  const manifest=path.join(root,'assignment.json');fs.writeFileSync(manifest,JSON.stringify(assignment),{mode:0o644});
  try {
    const child=spawn('docker',['run','--rm','--interactive','--name',name,'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--pids-limit','128','--memory','512m','--cpus','1',
      '--tmpfs','/tmp:rw,exec,nosuid,nodev,size=64m','--tmpfs','/workspace:rw,exec,nosuid,nodev,size=32m,uid=10001,gid=10001,mode=0700',
      '--mount','type=bind,src='+manifest+',dst=/control/assignment.json,readonly','--add-host','host.docker.internal:host-gateway',image,
      '--server','http://host.docker.internal:'+server.address().port,'--assignment','/control/assignment.json','--allow-http'],{stdio:['pipe','pipe','pipe']});
    let output='',errors='';child.stdout.on('data',chunk=>output+=chunk);child.stderr.on('data',chunk=>errors+=chunk);
    child.stdin.on('error',()=>{});child.stdin.end(token+'\n');
    timer=setTimeout(()=>{try{docker(['rm','-f',name]);}catch{}},90000);
    const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
    if(failure)throw failure;
    assert.equal(code,successful?0:1,errors+'\n'+output+'\n'+logs.join(''));
    const report=JSON.parse(output.trim());assert.equal(report.reported,true);
    assert.equal(completion?.conclusion,successful?'success':'failure');
    assert.equal(completion?.missing_capability || '',capability);
    assert.equal(docker(['ps','-aq','--filter','name=^'+name+'$']).trim(),'');
    console.log('EXECUTION_ROUTING_'+(capability || (successful?'SUCCESS':'ORDINARY_FAILURE'))+'_OK');
  } finally {
    clearTimeout(timer);try{docker(['rm','-f',name]);}catch{}
    server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(root,{recursive:true,force:true});
  }
}
(async()=>{
  await scenario('test "$(id -u)" = 10001; test ! -S /var/run/docker.sock; echo ordinary-job','',true);
  await scenario('docker build .; touch should-not-run','docker');
  await scenario('docker info || true; sleep 60','docker');
  await scenario('sudo -n apt-get update','container-root');
  await scenario('sudo -n sysctl -w kernel.core_pattern=core','host-kernel');
  await scenario('echo "Cannot connect to Docker daemon" >&2; exit 125','');
  await scenario('DOCKER_HOST=tcp://example.invalid docker info','');
})().catch(error=>{console.error(error);process.exitCode=1;});
