const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {DatabaseSync} = require('node:sqlite');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-production-test-'));
try {
  const file = path.join(root, 'test.db');
  const db = new DatabaseSync(file);
  db.exec('CREATE TABLE pipeline_job_attempt(status TEXT); CREATE TABLE pipeline_worker(state TEXT); CREATE TABLE pipeline_provider(name TEXT, repository_scope TEXT, revoked INTEGER);');
  const check = (provider) => spawnSync(process.execPath, ['--no-warnings', 'deploy/production-readiness.cjs', ...(provider ? [provider] : [])], {env:{...process.env,DB_PATH:file},encoding:'utf8'});
  assert.equal(check().status,0);
  db.exec("INSERT INTO pipeline_job_attempt VALUES('running')");
  assert.notEqual(check().status,0,'upgrade allowed an active task');
  db.exec("UPDATE pipeline_job_attempt SET status='completed'; INSERT INTO pipeline_worker VALUES('ready')");
  assert.notEqual(check().status,0,'upgrade allowed a worker to claim during backup');
  db.exec("UPDATE pipeline_worker SET state='drained'");
  assert.equal(check().status,0);
  db.exec("INSERT INTO pipeline_provider VALUES('asg','selected',0)");
  assert.notEqual(check('asg').status,0,'upgrade allowed restricted production scope');
  db.exec("UPDATE pipeline_provider SET repository_scope='all'");
  assert.equal(check('asg').status,0);
  db.close();
  const unit = spawnSync('python3', ['-c', `
import importlib.util
s = importlib.util.spec_from_file_location('unit', 'deploy/controller-unit.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
assert m.unit_quote('a %b $c') == '"a %%b $$c"'
try: m.unit_quote('bad' + chr(10) + 'ExecStart=evil')
except ValueError: pass
else: raise AssertionError('newline injection')
e = dict(MOONHUB_SERVER='https://example.invalid', MOONHUB_REGISTRATION_TOKEN_FILE='/private/token', MOONHUB_CONTROLLER_STATE_DIR='/private/state', MOONHUB_AWS_REGION='us-west-2', MOONHUB_ASG='on', MOONHUB_LAUNCH_TEMPLATE='lt-test', MOONHUB_INSTANCE_TYPES='m6a.large', MOONHUB_PARAMETER_PREFIX='/moonhub-runner/test', MOONHUB_TASK_IMAGE='registry/image:commit')
u = m.render(e)
assert 'RestartSec=65' in u and 'ReadWritePaths="/private/state"' in u
assert '--spot-asg' not in u
e['MOONHUB_SPOT_ASG']='spot'; assert '--spot-asg' in m.render(e)
`], {encoding:'utf8'});
  assert.equal(unit.status,0,unit.stderr);
  const syntax = spawnSync('bash',['-n','deploy/production.sh','deploy/worker-bootstrap.sh'],{encoding:'utf8'});
  assert.equal(syntax.status,0,syntax.stderr);
  const fixture = path.join(root, 'checkout');
  fs.mkdirSync(path.join(fixture, 'deploy'), {recursive:true});
  fs.mkdirSync(path.join(root, 'bin'));
  fs.copyFileSync('deploy/production.sh', path.join(fixture, 'deploy/production.sh'));
  fs.writeFileSync(path.join(fixture, '.gitignore'), `deploy/production.env
private-secret
`);
  const git = args => {const r=spawnSync('git',args,{cwd:fixture,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
  git(['init','-q']);git(['add','.']);git(['-c','user.name=Test','-c','user.email=test@example.invalid','-c','core.hooksPath=/dev/null','commit','-qm','fixture']);
  const revision=git(['rev-parse','HEAD']);
  fs.writeFileSync(path.join(fixture,'deploy/production.env'),`MOONHUB_COMPOSE_PROJECT_NAME=fixture
MOONHUB_AWS_REGION=us-west-2
MOONHUB_ECR_REPOSITORY=123456789012.dkr.ecr.us-west-2.amazonaws.com/runner
`);
  fs.writeFileSync(path.join(fixture,'private-secret'),'must not enter build');
  const log=path.join(root,'commands.jsonl'), marker=path.join(root,'built');
  fs.writeFileSync(path.join(root,'bin/docker'),`#!${process.execPath}
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const a=process.argv.slice(2);fs.appendFileSync(process.env.TEST_LOG,JSON.stringify(a)+String.fromCharCode(10));
if(a[0]==='image'){if(fs.existsSync(process.env.TEST_BUILT))console.log(process.env.TEST_REVISION);else process.exit(1);}
else if(a[0]==='info')console.log('linux/x86_64');
else if(a[0]==='inspect')process.exit(1);
else if(a[0]==='buildx' && a[1]==='bake'){
 const b=JSON.parse(fs.readFileSync(a[a.indexOf('--file')+1]));
 assert.deepEqual(b.group.default.targets,['web','runner','controller']);
 assert.equal(b.target.web.labels['org.opencontainers.image.revision'],process.env.TEST_REVISION);
 assert.ok(!fs.existsSync(path.join(b.target.web.context,'private-secret')));
 assert.ok(!fs.existsSync(path.join(b.target.web.context,'deploy/production.env')));
 if(process.env.TEST_BUILD_FAIL==='1')process.exit(7);
 fs.writeFileSync(process.env.TEST_BUILT,'yes');
}
`,{mode:0o755});
  fs.writeFileSync(path.join(root,'bin/df'),`#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 90000000 0 90000000 0%% /\n'
`,{mode:0o755});
  const runBuild = fail => spawnSync('bash',['deploy/production.sh','build'],{cwd:fixture,encoding:'utf8',env:{...process.env,PATH:path.join(root,'bin')+':'+process.env.PATH,TEST_LOG:log,TEST_BUILT:marker,TEST_REVISION:revision,TEST_BUILD_FAIL:fail?'1':'0',MOONHUB_PRODUCTION_LOCK_DIR:path.join(root,'lock')}});
  let built=runBuild(true);assert.notEqual(built.status,0,built.stdout);
  let calls=fs.readFileSync(log,'utf8').trim().split(String.fromCharCode(10)).map(JSON.parse);
  assert.ok(calls.some(a=>a[0]==='stop'),'failed build left builder running');
  assert.ok(!calls.some(a=>a[0]==='compose'),'build touched application services');
  const create=calls.find(a=>a[0]==='run');assert.ok(create.includes('--cpus') && create.includes('4g') && create.includes('512'));
  built=runBuild(false);assert.equal(built.status,0,built.stderr);
  console.log('Production deployment: blocks active/claimable work; renders safe controller unit; shell syntax passed.');
} finally { fs.rmSync(root,{recursive:true,force:true}); }
