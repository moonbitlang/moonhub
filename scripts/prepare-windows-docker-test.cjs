const assert = require('node:assert/strict');
const {test} = require('node:test');
const {prepareWindowsDocker} = require('./prepare-windows-docker.cjs');
const ready = {status:0,stdout:JSON.stringify({OSType:'windows',Architecture:'amd64'})};
const unavailable = {status:1,stderr:'open //./pipe/docker_engine: The system cannot find the file specified.'};

function fixture(probes, service = {status:0,stdout:'docker Running Automatic'}) {
  const calls=[],logs=[];let time=0,index=0;
  return {
    calls, logs,
    options: {
      run(program,args,options) {
        calls.push({program,args,options});
        if(program === 'docker.exe') {
          assert.deepEqual(args,['--host','npipe:////./pipe/docker_engine','info','--format','{{json .}}']);
          return probes[Math.min(index++,probes.length-1)];
        }
        assert.equal(program,'powershell.exe');
        return service;
      },
      now:()=>time,
      sleep:async ms=>{time+=ms;},
      log:text=>logs.push(text),
      timeoutMs:6000,
    },
  };
}

test('a ready local Windows daemon does not restart its service', async () => {
  const f=fixture([ready]);await prepareWindowsDocker(f.options);
  assert.equal(f.calls.length,1);
});
test('missing named pipe starts Docker then waits for real API readiness', async () => {
  const f=fixture([unavailable,unavailable,ready]);await prepareWindowsDocker(f.options);
  assert.equal(f.calls.filter(call=>call.program === 'powershell.exe').length,1);
  assert.match(f.calls[1].args.at(-1),/Get-Service -Name docker/);
  assert.match(f.calls[1].args.at(-1),/Status -ne 'Running'.*Start-Service/);
  assert.doesNotMatch(f.calls[1].args.at(-1),/Restart-Service|Stop-Service|download|install/i);
  assert.equal(f.calls.filter(call=>call.program === 'docker.exe').length,3);
});
test('an unreachable daemon has a deadline, bounded probes and service diagnostics', async () => {
  const f=fixture([unavailable]);await assert.rejects(prepareWindowsDocker(f.options),/within 6000ms.*cannot find/);
  assert.equal(f.calls.filter(call=>call.program === 'docker.exe').length,3);
  assert.match(f.calls.at(-1).args.at(-1),/docker,hns,vmcompute/);
  assert.ok(f.calls.every(call=>call.options.timeout<=10000));
});
test('a failed service start stops before any image command', async () => {
  const f=fixture([unavailable],{status:1,stderr:'service startup failed'});
  await assert.rejects(prepareWindowsDocker(f.options),/Could not start.*service startup failed/);
  assert.equal(f.calls.length,2);
});
test('a different Docker platform fails without switching engine or service', async () => {
  for(const info of [{OSType:'linux',Architecture:'amd64'},{OSType:'windows',Architecture:'arm64'}]) {
    const f=fixture([{status:0,stdout:JSON.stringify(info)}]);
    await assert.rejects(prepareWindowsDocker(f.options),/local Windows x64/);
    assert.equal(f.calls.length,1);
  }
});
test('malformed Docker metadata fails closed', async () => {
  const f=fixture([{status:0,stdout:'not-json'}]);
  await assert.rejects(prepareWindowsDocker(f.options),/invalid platform/);
});
