// Test guest task dispatch on the fresh Windows Server 2025 CI VM.
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {randomBytes} = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const install = 'C:/moonhub';
const state = 'C:/ProgramData/MoonHub';
const shell = install + '/pwsh/pwsh.exe';
const testTask = 'MoonHubWindowsVmTest';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const powershell = source => execFileSync(shell, ['-NoProfile', '-NonInteractive', '-Command',
  "$ErrorActionPreference='Stop'; " + source], {encoding: 'utf8', timeout: 15000});

async function runGuestJob(administrator) {
  const token = randomBytes(32).toString('hex');
  const attemptId = administrator ? '2' : '1';
  const directory = state + '/workspace/' + attemptId;
  let executionId = '', conclusion = '', sequence = 0;
  let logs = '', failure, receivedStart = false;
  const server = http.createServer(async (request, response) => {
    try {
      assert.equal(request.headers.authorization, 'Bearer ' + token);
      assert.equal(request.method, 'POST', 'The guest fixture has no source access');
      let input = '';
      for await (const chunk of request) input += chunk;
      const body = JSON.parse(input);
      const action = request.url.split('/').at(-1);
      if (action === 'start') {
        receivedStart = true;
        executionId = body.execution_id;
      }
      if (action === 'logs') {
        assert.equal(Number(body.sequence), ++sequence);
        logs += body.text;
      }
      if (action === 'complete') conclusion = body.conclusion;
      const now = Date.now();
      response.writeHead(200, {'Content-Type': 'application/json'});
      response.end(JSON.stringify({
        version: 1, attempt_id: attemptId, execution_id: executionId,
        state: conclusion ? 'completed' : 'running', conclusion,
        server_time_ms: String(now), lease_until_ms: String(now + 60000),
        deadline_ms: String(now + 120000), cancel_requested: false, log_sequence: String(sequence),
      }));
    } catch (error) {
      failure = error;
      response.writeHead(500).end('{}');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    fs.mkdirSync(directory, {recursive: true});
    fs.writeFileSync(directory + '/dispatch.json', JSON.stringify({
      administrator, token, allow_http: true, server: 'http://127.0.0.1:' + server.address().port,
    }));
    const now = Date.now();
    const run = [
      '$identity = [Security.Principal.WindowsIdentity]::GetCurrent()',
      "if ($identity.Name -notlike '*\\MoonHubJob') { throw 'Unexpected job account' }",
      '$principal = [Security.Principal.WindowsPrincipal]::new($identity)',
      "$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)",
      (administrator ? "if (!$admin)" : "if ($admin)") + " { throw 'Unexpected administrator state' }",
      "$target = Join-Path (Get-Location) 'target.txt'",
      "$alias = Join-Path (Get-Location) 'alias.txt'",
      "[IO.File]::WriteAllText($target, 'moonhub')",
      "Add-Type -Namespace MoonHub -Name Win32 -MemberDefinition @'",
      '[DllImport("kernel32.dll", EntryPoint = "CreateSymbolicLinkW", CharSet = CharSet.Unicode, SetLastError = true)]',
      '[return: MarshalAs(UnmanagedType.I1)]',
      'public static extern bool CreateSymbolicLink(string link, string target, uint flags);',
      "'@",
      'if (![MoonHub.Win32]::CreateSymbolicLink($alias, $target, 0)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }',
      "if ([IO.File]::ReadAllText($alias) -ne 'moonhub') { throw 'File symlink failed' }",
      "Write-Output 'VM_JOB_ACCOUNT_AND_SYMLINK_OK'",
    ].join('\n');
    const labels = ['self-hosted', 'windows', 'x64', 'windows-2025'];
    if (administrator) labels.push('windows-vm');
    fs.writeFileSync(directory + '/assignment.json', JSON.stringify({
      version: 11, attempt_id: attemptId, run_id: '1', job_id: '1',
      repository: 'test/windows-vm', commit_sha: 'a'.repeat(40), state: 'leased',
      server_time_ms: String(now), lease_until_ms: String(now + 60000),
      job: {id: 'test', name: 'VM guest test', runs_on: labels, timeout_minutes: 2, contents_read: false,
        steps: [{id: 'check', name: 'Check account', run, shell: '', working_directory: '.', env: {}, timeout_minutes: 0}]},
    }));
    const testScript = state + '/dispatch-test.ps1';
    fs.writeFileSync(testScript, [
      "$ErrorActionPreference = 'Stop'",
      "try { & 'C:/moonhub/ci-host.ps1' -PrepareJobAccount; & 'C:/moonhub/ci-host.ps1' -StartJob " + attemptId + " }",
      "catch { $_ | Out-String | Set-Content 'C:/ProgramData/MoonHub/dispatch-test-error'; exit 1 }",
    ].join('\r\n'));
    powershell("$action=New-ScheduledTaskAction -Execute '" + shell + "' -Argument '-NoProfile -NonInteractive -File " + testScript +
      "'; Register-ScheduledTask -TaskName '" + testTask + "' -Action $action -User SYSTEM -RunLevel Highest | Out-Null; Start-ScheduledTask -TaskName '" + testTask + "'");
    const errorPath = state + '/dispatch-test-error';
    const until = Date.now() + 65000;
    while (!conclusion && !failure && !fs.existsSync(errorPath) && Date.now() < until) await sleep(200);
    if (failure) throw failure;
    if (fs.existsSync(errorPath)) throw Error(fs.readFileSync(errorPath, 'utf8'));
    assert.ok(receivedStart, 'VM executor did not contact the server');
    assert.equal(conclusion, 'success', logs);
    assert.match(logs, /VM_JOB_ACCOUNT_AND_SYMLINK_OK/);
    assert.ok(!fs.existsSync(directory + '/dispatch.json'), 'Attempt credential file was retained');
    assert.ok(!fs.existsSync(state + '/private/job-account'), 'The prepared account password file was retained');
    console.log('Windows VM ' + (administrator ? 'administrator' : 'ordinary') + ' account and file symlink verified');
  } finally {
    powershell("foreach ($name in '" + testTask + "','MoonHubWindowsVmJob') { if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $name; Unregister-ScheduledTask -TaskName $name -Confirm:$false } } " +
      "if (Get-LocalUser -Name MoonHubJob -ErrorAction SilentlyContinue) { Remove-LocalUser -Name MoonHubJob }");
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

async function main() {
  assert.equal(process.platform, 'win32');
  assert.ok(!fs.existsSync(install) && !fs.existsSync(state), 'Requires a clean Windows Server CI guest');
  fs.cpSync(path.resolve('.tmp/windows-runner'), install, {recursive: true});
  fs.mkdirSync(state + '/private', {recursive: true});
  fs.mkdirSync(state + '/vm');
  fs.writeFileSync(state + '/vm/isolated', '');
  try {
    await runGuestJob(false);
    await runGuestJob(true);
  } finally {
    fs.rmSync(state, {recursive: true, force: true});
    fs.rmSync(install, {recursive: true, force: true});
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
