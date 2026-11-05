const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const launcher = path.resolve('.tmp/windows-runner/bin/moonhub-runner-step.exe');
async function scenario(cancel) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub process tree '));
  const pidFile = path.join(root, 'pid');
  const probe = path.join(root, 'probe.cjs');
  fs.writeFileSync(probe, `const {spawn} = require('node:child_process'); const child = spawn(process.execPath, ['-e','setInterval(()=>{},1000)'], {detached:true,stdio:'ignore'}); child.unref(); require('node:fs').writeFileSync(process.env.PROBE_PID, String(child.pid)); ${cancel ? 'setInterval(()=>{},1000)' : ''}`);
  const script = path.join(root, 'step.ps1');
  fs.writeFileSync(script, '& $env:PROBE_NODE $env:PROBE_SCRIPT\nexit $LASTEXITCODE\n');
  const child = spawn(launcher, ['pwsh', script], { env: {...process.env, PROBE_NODE:process.execPath, PROBE_SCRIPT:probe, PROBE_PID:pidFile}, stdio:'inherit' });
  const closed = new Promise((resolve,reject) => {child.once('error',reject); child.once('close',resolve);});
  try {
    for (let i=0; i<200 && !fs.existsSync(pidFile); i++) await delay(50);
    assert.ok(fs.existsSync(pidFile), 'grandchild did not start');
    const pid = Number(fs.readFileSync(pidFile,'utf8'));
    if (cancel) child.kill('SIGKILL');
    const code = await Promise.race([closed, delay(15000).then(()=>{throw Error('launcher did not stop');})]);
    if (!cancel) assert.equal(code, 0);
    let alive = true;
    for (let i=0; i<100; i++) {
      try {process.kill(pid,0);} catch {alive=false; break;}
      await delay(50);
    }
    assert.equal(alive,false,'detached grandchild survived the step Job Object');
    console.log(`${cancel ? 'Cancellation' : 'Success'}: Windows process tree cleaned`);
  } finally {child.kill('SIGKILL'); await closed; fs.rmSync(root,{recursive:true,force:true});}
}
async function startupGate() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub startup gate '));
  const marker = path.join(root, 'executed');
  const script = path.join(root, 'step.ps1');
  fs.writeFileSync(script, "[IO.File]::WriteAllText($env:PROBE_MARKER, 'bad')");
  const child = spawn(launcher, ['pwsh', script, '--wait-for-agent'], {env:{...process.env,PROBE_MARKER:marker},stdio:['pipe','inherit','inherit']});
  const closed = new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
  try {
    await delay(300);
    assert.equal(fs.existsSync(marker),false,'untrusted shell started before the agent retained a handle');
    child.stdin.end();
    assert.equal(await Promise.race([closed,delay(10000).then(()=>{throw Error('launcher ignored startup gate EOF');})]),125);
    assert.equal(fs.existsSync(marker),false,'gate EOF executed a shell');
    console.log('Startup: no shell before agent acknowledgement; EOF fails closed');
  } finally { child.kill('SIGKILL'); await closed; fs.rmSync(root,{recursive:true,force:true}); }
}
(async()=>{assert.equal(process.platform,'win32'); await startupGate(); await scenario(false); await scenario(true);})().catch(error=>{console.error(error);process.exitCode=1;});
