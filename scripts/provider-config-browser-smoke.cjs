const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const { createRequire } = require('node:module');
const { chromium } = createRequire(path.resolve(__dirname, '../js/package.json'))('playwright');

const root = path.resolve(__dirname, '..');
const output = path.join(root, '_build', 'provider-config-browser');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-provider-config-'));
const password = randomBytes(24).toString('hex');
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
let server, browser, controller, keep = false;
let controllerOutput = '';

async function until(check, message) {
  for (let i = 0; i < 150; i++) {
    if (await check()) return;
    if (controller && controller.exitCode !== null) throw new Error('Runner exited: ' + controllerOutput);
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  throw new Error(message);
}

async function capture(page, state) {
  for (const [name, width] of [['desktop', 1280], ['mobile', 390], ['small-mobile', 320]]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForFunction(() => document.documentElement.dataset.hydrated === 'true');
    await page.evaluate(() => document.fonts.ready);
    // Full-page captures preserve sticky elements at their current scroll offset.
    // Reset test focus and scroll before capturing the page, not production CSS.
    await page.evaluate(async () => {
      if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
      window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    const shell = await page.evaluate(() => ({
      headers: document.querySelectorAll('.site-header').length,
      sidebars: document.querySelectorAll('#app-sidebar').length,
      mains: document.querySelectorAll('#main-content').length,
      pages: document.querySelectorAll('#moonhub-page').length,
    }));
    if (shell.headers !== 1 || shell.sidebars !== 1 || shell.mains !== 1 || shell.pages !== 1) {
      fs.writeFileSync(path.join(output, 'duplicate-shell.html'), await page.content());
    }
    assert.deepEqual(shell, { headers: 1, sidebars: 1, mains: 1, pages: 1 }, `${state}/${name}: single page shell`);
    await page.waitForFunction(() => {
      const sidebar = document.querySelector('#app-sidebar');
      if (!sidebar || getComputedStyle(sidebar).position !== 'fixed') return true;
      return getComputedStyle(sidebar).visibility === 'hidden' && sidebar.getBoundingClientRect().right <= 1;
    });
    const layout = await page.evaluate(() => {
      const width = document.documentElement.clientWidth;
      const controls = [...document.querySelectorAll('main a, main button, main select, main summary, main input:not([type=hidden])')].filter(e => e.checkVisibility());
      const outside = controls.filter(e => { const r = e.getBoundingClientRect(); return r.left < -1 || r.right > width + 1; }).map(e => e.textContent || e.id);
      const overlaps = [];
      for (let i = 0; i < controls.length; i++) for (let j = i + 1; j < controls.length; j++) {
        if (controls[i].contains(controls[j]) || controls[j].contains(controls[i])) continue;
        const a = controls[i].getBoundingClientRect(), b = controls[j].getBoundingClientRect();
        if (Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1) overlaps.push([controls[i].id, controls[j].id]);
      }
      return { overflow: document.documentElement.scrollWidth > width, outside, overlaps };
    });
    assert.deepEqual(layout, { overflow: false, outside: [], overlaps: [] }, `${state}/${name}`);
    const geometry = await page.evaluate(() => ({
      viewport: [innerWidth, innerHeight],
      scroll: [scrollX, scrollY],
      document: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
      shells: [...document.querySelectorAll('.site-header, #app-sidebar, #main-content')].map(element => {
        const r = element.getBoundingClientRect();
        return { name: element.id || element.className, top: r.top, bottom: r.bottom, height: r.height };
      }),
      workersGap: document.querySelector('.provider-execution-workers').getBoundingClientRect().top - document.querySelector('form.form-stack').getBoundingClientRect().bottom,
      skipLinkBottom: document.querySelector('.skip-link').getBoundingClientRect().bottom,
    }));
    assert.deepEqual(geometry.scroll, [0, 0], `${state}/${name}: full-page capture starts at top`);
    assert.equal(geometry.shells[0].top, 0, `${state}/${name}: header stays at viewport top`);
    assert.ok(geometry.skipLinkBottom <= 0, `${state}/${name}: unfocused skip link stays outside viewport`);
    assert.ok(geometry.workersGap >= 24, `${state}/${name}: workers section spacing`);
    fs.writeFileSync(path.join(output, `${state}-${name}.json`), JSON.stringify(geometry, null, 2));
    await page.screenshot({ path: path.join(output, `${state}-${name}-viewport.png`), fullPage: false, animations: 'disabled' });
    await page.screenshot({ path: path.join(output, `${state}-${name}.png`), fullPage: true, animations: 'disabled' });
  }
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(root, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  server = spawn(binary, [path.join(temp, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root', '--root-password-file', path.join(temp, 'password')], {
    cwd: temp, env, detached: true, stdio: ['ignore', log, log],
  });
  fs.closeSync(log);
  let ready = false;
  for (let i = 0; i < 100; i++) {
    if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8'));
    try { ready = (await fetch(base + '/-/login')).ok; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.ok(ready, 'local test server never started');
  let cookie;
  async function post(route, fields) {
    const response = await fetch(base + route, { method: 'POST', redirect: 'manual', headers: cookie ? { Cookie: cookie } : {}, body: new URLSearchParams(fields) });
    if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
    await response.text();
    assert.equal(response.status, 303);
  }
  await post('/-/login', { name_key: 'root', password });
  await post('/-/change-password', { new_password: password, confirm_password: password });
  const tokenFile = path.join(temp, 'provider-token');
  fs.writeFileSync(tokenFile, randomBytes(32).toString('hex'), { mode: 0o600 });
  execFileSync(binary, ['pipeline-provider-create', '--name', 'dind', '--token-file', tokenFile, '--admin', 'root'], { cwd: temp, env, stdio: 'pipe' });
  // Run the real CLI against the real MoonHub server; only AWS is simulated.
  const cloudState = path.join(temp, 'cloud.json');
  fs.writeFileSync(cloudState, JSON.stringify({ configurations: [] }));
  const adapter = path.join(temp, 'aws-adapter');
  fs.writeFileSync(adapter, `#!${process.execPath}
const fs = require('node:fs'), assert = require('node:assert/strict');
const args = process.argv.slice(2), file = ${JSON.stringify(cloudState)};
const state = JSON.parse(fs.readFileSync(file));
let result = null;
if (args[0] === 'ec2' && args[1] === 'describe-instance-types') result = [{cpus:2,memory_mib:8192,architectures:['x86_64']}];
else if (args[0] === 'ec2' && args[1] === 'describe-launch-template-versions') result = [{image:'ami-local',tokens:'required',hop:1}];
else if (args[0] === 'ec2' && args[1] === 'describe-images') result = ['x86_64'];
else if (args[0] === 'autoscaling' && args[1] === 'describe-auto-scaling-groups') {
  result = [{name:args[args.indexOf('--auto-scaling-group-names')+1],min:0,max:3,desired:0,instances:[]}];
} else if (args[0] === 'autoscaling' && args[1] === 'update-auto-scaling-group') {
  const input = args[args.indexOf('--cli-input-json')+1];
  const request = JSON.parse(fs.readFileSync(input.slice(7)));
  assert.equal(request.NewInstancesProtectedFromScaleIn, true);
  state.configurations.push(request.MixedInstancesPolicy.LaunchTemplate.Overrides[0].InstanceType);
  fs.writeFileSync(file, JSON.stringify(state));
} else if (args[0] === 'autoscaling' && args[1] === 'set-desired-capacity') {
  state.requested = Number(args[args.indexOf('--desired-capacity')+1]);
  fs.writeFileSync(file, JSON.stringify(state));
} else throw Error('Unexpected AWS command: '+args.slice(0,2).join(' '));
if (result !== null) console.log(JSON.stringify(result));
`, { mode: 0o700 });
  const runnerBinary = process.env.MOONHUB_RUNNER_BINARY || path.join(root, '_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe');
  const controllerState = path.join(temp, 'controller');
  controller = spawn(runnerBinary, [
    'run', '--server', base, '--allow-http', '--name', 'dind', '--mode', 'asg',
    '--registration-token-file', tokenFile, '--state-dir', controllerState,
    '--aws', adapter, '--asg', 'local-on-demand', '--spot-asg', 'local-spot',
    '--launch-template', 'lt-local', '--instance-types', 'm6a.large,c6a.large',
    '--runner-image', 'moonhub:runner',
  ], { cwd: temp, env, stdio: ['ignore', 'pipe', 'pipe'] });
  controller.stdout.on('data', data => { controllerOutput += data; });
  controller.stderr.on('data', data => { controllerOutput += data; });
  await until(() => fs.existsSync(path.join(controllerState, 'registered.json')), 'Runner registration timed out');
  await until(() => JSON.parse(fs.readFileSync(cloudState)).configurations.length >= 2, 'Initial configuration never reached the backend');
  assert.equal(fs.statSync(path.join(controllerState, 'provider-token')).mode & 0o777, 0o600);
  browser=await chromium.launch({headless:true,...(process.env.CHROMIUM_EXECUTABLE ? {executablePath:process.env.CHROMIUM_EXECUTABLE} : {})});
  const context=await browser.newContext();
  const split=cookie.indexOf('=');
  await context.addCookies([{name:cookie.slice(0,split),value:cookie.slice(split+1),url:base}]);
  const page=await context.newPage();
  const errors=[]; page.on('pageerror',e => errors.push(e.message));
  await page.goto(base+'/-/admin/pipelines/providers');
  await page.getByRole('link',{name:'Configure dind',exact:true}).click();
  await page.getByRole('heading',{name:'Execution settings',exact:true}).waitFor();
  assert.equal(await page.getByLabel('Runner image',{exact:true}).inputValue(),'moonhub:runner');
  assert.equal(await page.locator('form.form-stack .field').count(), 10);
  assert.equal(await page.getByLabel('Standby workers', { exact: true }).inputValue(), '0');
  assert.equal(await page.getByLabel('Memory limit per task (MiB)', { exact: true }).inputValue(), '4096');
  await capture(page,'settings');
  await page.getByLabel('CPU limit per task',{exact:true}).fill('1');
  await page.getByLabel('Instance type',{exact:true}).selectOption('c6a.large');
  await page.getByLabel('Standby workers', {exact:true}).fill('1');
  await page.getByRole('button',{name:'Save configuration',exact:true}).click();
  await page.getByRole('status').filter({hasText:'Configuration 2'}).waitFor();
  assert.equal(await page.getByLabel('CPU limit per task',{exact:true}).inputValue(),'1');
  assert.equal(await page.getByLabel('Instance type',{exact:true}).inputValue(),'c6a.large');
  assert.equal(await page.getByLabel('Standby workers', {exact:true}).inputValue(),'1');
  await until(() => JSON.parse(fs.readFileSync(cloudState)).configurations.filter(type => type === 'c6a.large').length >= 2, 'Saved configuration never reached both ASGs');
  await until(async () => {
    await page.reload();
    return /Configuration 2 · observed 2 · applied 2/.test(await page.getByRole('status').innerText());
  }, 'Runner never acknowledged revision 2');
  await until(() => JSON.parse(fs.readFileSync(cloudState)).requested === 1, 'Standby capacity was not requested for the empty queue');
  // Seed only this isolated test database; production identities are untouched.
  execFileSync('python3', ['-c', `
import sqlite3,sys,time
db=sqlite3.connect(sys.argv[1]);now=int(time.time()*1000)
provider=db.execute("SELECT id FROM pipeline_provider WHERE name='dind'").fetchone()[0]
for key,state,draining in [('current-worker','ready',0),('draining-worker','ready',1),('old-failed-worker','failed',1),('stopped-worker','drained',1)]:
 db.execute("INSERT INTO pipeline_worker(provider_id,worker_key,token_hash,state,draining,applied_revision,last_seen_ms,idle_since_ms) VALUES(?,?,?,?,?,2,?,?)",(provider,key,'fixture-'+key,state,draining,now,now))
db.commit()
`, env.DB_PATH]);
  await page.reload();
  const currentWorkers = page.locator('[data-current-workers]');
  const workerHistory = page.locator('.provider-worker-history');
  await page.getByRole('heading', { name: 'Current workers (2)', exact: true }).waitFor();
  assert.equal(await currentWorkers.locator('li').count(), 2);
  assert.ok((await currentWorkers.innerText()).includes('current-worker'));
  assert.ok((await currentWorkers.innerText()).includes('draining-worker'));
  assert.ok(!(await currentWorkers.innerText()).includes('old-failed-worker'));
  assert.equal(await workerHistory.getAttribute('open'), null);
  assert.equal(await page.locator('[data-worker-history]').isVisible(), false);
  await capture(page,'saved');
  const summary = workerHistory.locator('summary');
  await summary.focus();
  await page.keyboard.press('Enter');
  assert.equal(await page.locator('[data-worker-history]').isVisible(), true);
  assert.equal(await page.locator('[data-worker-history] li').count(), 2);
  const historicalText = await page.locator('[data-worker-history]').innerText();
  assert.ok(historicalText.includes('Stopped') && historicalText.includes('Failed'));
  assert.ok(!historicalText.includes('draining'));
  await capture(page,'history-open');
  await summary.focus();
  await page.keyboard.press('Space');
  assert.equal(await page.locator('[data-worker-history]').isVisible(), false);
  // Direct SSR hydration and repeated SPA navigation must each retain one shell.
  await page.reload();
  await page.waitForFunction(() => document.documentElement.dataset.hydrated === 'true');
  assert.equal(await page.locator('.site-header').count(), 1);
  assert.equal(await page.locator('#app-sidebar').count(), 1);
  assert.equal(await page.locator('#main-content').count(), 1);
  assert.equal(await page.getByLabel('CPU limit per task', { exact: true }).inputValue(), '1');
  await page.getByRole('link', { name: 'Pipeline providers', exact: true }).click();
  await page.getByRole('link', { name: 'Configure dind', exact: true }).click();
  await page.getByRole('heading', { name: 'Execution settings', exact: true }).waitFor();
  assert.equal(await page.locator('.site-header').count(), 1);
  assert.equal(await page.locator('#moonhub-page').count(), 1);
  const route = new URL(page.url()).pathname;
  assert.match(route, /^\/-\/admin\/pipelines\/providers\/[1-9][0-9]*\/configuration$/);
  const csrf=await page.locator('input[name=csrf_token]').inputValue();
  const current = await page.locator('form.form-stack').evaluate(form => Object.fromEntries(new FormData(form)));
  const conflict=await context.request.post(base+route,{form:{...current,csrf_token:csrf,revision:'1',config_runner_image:'stale'}});
  assert.equal(conflict.status(),409);
  assert.ok((await conflict.text()).includes('Configuration changed'));
  const invalid=await context.request.post(base+route,{form:{...current,csrf_token:csrf,revision:'2',config_runner_image:'<invalid>'+String.fromCharCode(10)}});
  assert.equal(invalid.status(),400);
  await page.setContent(await invalid.text());
  await page.getByRole('alert').waitFor();
  assert.equal(await page.locator('invalid').count(),0);
  assert.equal(await page.getByLabel('Runner image', { exact: true }).getAttribute('value'), '<invalid>'+String.fromCharCode(10));
  assert.deepEqual(errors,[]);
  assert.ok(!controllerOutput.includes(fs.readFileSync(path.join(controllerState, 'provider-token'), 'utf8')));
  console.log('Provider configuration acceptance passed: real CLI enrollment, full ASG schema, applied revision, CAS conflict, escaping, single page shell, worker history keyboard disclosure, desktop and mobile.');
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({ base, pid: server.pid, directory: temp, username: 'root', passwordFile: path.join(temp, 'password') }, null, 2), { mode: 0o600 });
    keep = true;
    server.unref();
    console.log(`Local provider-config preview retained: ${base}/-/admin/pipelines/providers; credentials: ${path.join(output, 'preview.json')}`);
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (controller && controller.exitCode === null) {
    const exited = new Promise(resolve => controller.once('exit', resolve));
    controller.kill('SIGTERM');
    const timeout = setTimeout(() => controller.kill('SIGKILL'), 5000);
    await exited;
    clearTimeout(timeout);
  }
  if (!keep) {
    if (server && server.exitCode === null) {
      const exited = new Promise(resolve => server.once('exit', resolve));
      process.kill(-server.pid, 'SIGTERM');
      await exited;
    }
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
