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
  db.exec(`CREATE TABLE pipeline_job_attempt(status TEXT);
    CREATE TABLE pipeline_worker(state TEXT, provider_id INTEGER);
    CREATE TABLE pipeline_provider(id INTEGER PRIMARY KEY, name TEXT, repository_scope TEXT, revoked INTEGER, paused INTEGER, mode TEXT, config_revision INTEGER, applied_revision INTEGER);`);
  const check = (provider, idle = false) => spawnSync(process.execPath, ['--no-warnings', 'deploy/production-readiness.cjs', ...(provider ? [provider] : []), ...(idle ? ['--allow-idle-workers'] : [])], {env:{...process.env,DB_PATH:file},encoding:'utf8'});
  const providerState = (operation, argument) => spawnSync(process.execPath, ['--no-warnings', 'deploy/production-provider-state.cjs', operation, argument], {env:{...process.env,DB_PATH:file},encoding:'utf8'});
  assert.equal(check().status,0);
  db.exec("INSERT INTO pipeline_job_attempt VALUES('running')");
  assert.notEqual(check().status,0,'upgrade allowed an active task');
  db.exec("UPDATE pipeline_job_attempt SET status='completed'; INSERT INTO pipeline_worker VALUES('ready',1)");
  assert.notEqual(check().status,0,'upgrade allowed a worker to claim during backup');
  db.exec("UPDATE pipeline_worker SET state='drained'");
  assert.equal(check().status,0);
  db.exec("INSERT INTO pipeline_provider VALUES(1,'asg','selected',0,0,'asg',1,1)");
  assert.notEqual(check('asg').status,0,'upgrade allowed restricted production scope');
  assert.notEqual(providerState('pause','asg').status,0);
  db.exec("UPDATE pipeline_provider SET repository_scope='all'; UPDATE pipeline_worker SET state='ready'");
  assert.notEqual(check('asg',true).status,0,'unpaused worker can claim');
  let pause=providerState('pause','asg');
  assert.equal(pause.status,0,pause.stderr);
  const journal=pause.stdout.trim();
  assert.deepEqual(JSON.parse(journal),{id:'1',name:'asg',paused:0});
  assert.equal(db.prepare('SELECT paused FROM pipeline_provider').get().paused,1);
  for (const state of ['starting','ready','drained','failed']) {
    db.prepare('UPDATE pipeline_worker SET state=?').run(state);
    const ready=check('asg',true);assert.equal(ready.status,0,ready.stderr);
  }
  db.exec("UPDATE pipeline_worker SET state='busy'");
  assert.notEqual(check('asg',true).status,0,'cleanup in progress bypassed readiness');
  db.exec("UPDATE pipeline_worker SET state='ready'; UPDATE pipeline_provider SET config_revision=2");
  assert.notEqual(check('asg',true).status,0,'pending execution settings bypassed drain');
  db.exec("UPDATE pipeline_provider SET applied_revision=2; INSERT INTO pipeline_provider VALUES(2,'dind','all',0,0,'docker',1,1); INSERT INTO pipeline_worker VALUES('ready',2)");
  assert.notEqual(check('asg',true).status,0,'another provider can claim');
  const allPaused = providerState('pause-all','asg');
  assert.equal(allPaused.status,0,allPaused.stderr);
  const allJournal = JSON.parse(allPaused.stdout);
  assert.deepEqual(allJournal.providers,[{id:'1',name:'asg',paused:1},{id:'2',name:'dind',paused:0}]);
  assert.equal(check('asg',true).status,0,'paused idle Docker worker blocked the Web switch');
  for (const state of ['busy','starting']) {
    db.prepare('UPDATE pipeline_worker SET state=? WHERE provider_id=2').run(state);
    assert.notEqual(check('asg',true).status,0,'unsafe Docker worker bypassed readiness');
  }
  db.exec("UPDATE pipeline_worker SET state='ready'; UPDATE pipeline_provider SET config_revision=2 WHERE id=2");
  assert.notEqual(check('asg',true).status,0,'unapplied secondary configuration bypassed readiness');
  db.exec("UPDATE pipeline_provider SET config_revision=1 WHERE id=2; UPDATE pipeline_provider SET name='replacement' WHERE id=2");
  assert.notEqual(providerState('restore',allPaused.stdout).status,0,'changed secondary identity was restored');
  assert.deepEqual(db.prepare('SELECT paused FROM pipeline_provider ORDER BY id').all().map(p=>p.paused),[1,1],'partial restore escaped rollback');
  db.exec("UPDATE pipeline_provider SET name='dind' WHERE id=2");
  assert.equal(providerState('restore',allPaused.stdout).status,0);
  assert.deepEqual(db.prepare('SELECT paused FROM pipeline_provider ORDER BY id').all().map(p=>p.paused),[1,0]);
  db.exec("INSERT INTO pipeline_job_attempt VALUES('running')");
  assert.notEqual(providerState('pause-all','asg').status,0,'all-provider pause allowed active work');
  assert.equal(db.prepare('SELECT paused FROM pipeline_provider WHERE id=2').get().paused,0,'failed pause changed another provider');
  db.exec("DELETE FROM pipeline_job_attempt WHERE status='running'; DELETE FROM pipeline_worker WHERE provider_id=2; DELETE FROM pipeline_provider WHERE id=2");
  assert.equal(providerState('restore',journal).status,0);
  assert.equal(db.prepare('SELECT paused FROM pipeline_provider').get().paused,0);
  db.exec('UPDATE pipeline_provider SET paused=1');
  pause=providerState('pause','asg');
  assert.equal(providerState('restore',pause.stdout.trim()).status,0);
  assert.equal(db.prepare('SELECT paused FROM pipeline_provider').get().paused,1);
  db.exec("UPDATE pipeline_provider SET paused=0; INSERT INTO pipeline_job_attempt VALUES('leased')");
  assert.notEqual(providerState('pause','asg').status,0,'pause did not reject active work');
  assert.equal(db.prepare('SELECT paused FROM pipeline_provider').get().paused,0);
  db.exec("DELETE FROM pipeline_job_attempt WHERE status='leased'; UPDATE pipeline_provider SET revoked=1");
  assert.notEqual(providerState('restore',journal).status,0,'restored revoked provider');
  db.exec("UPDATE pipeline_provider SET revoked=0,name='replacement'");
  assert.notEqual(providerState('restore',journal).status,0,'restored replacement identity');
  pause=providerState('pause','missing');
  assert.equal(pause.status,0,pause.stderr);
  assert.equal(providerState('restore',pause.stdout.trim()).status,0);
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
assert m.equivalent(u, u.replace('registry/image:commit','registry/image:new-commit'))
assert not m.equivalent(u, u.replace('lt-test','lt-other'))
assert not m.equivalent(u, u.replace('MemoryMax=256M','MemoryMax=512M'))
assert not m.equivalent('unrecognized', 'unrecognized')
e['MOONHUB_SPOT_ASG']='spot'; assert '--spot-asg' in m.render(e)
`], {encoding:'utf8'});
  assert.equal(unit.status,0,unit.stderr);
  const syntax = spawnSync('bash',['-n','deploy/production.sh','deploy/worker-bootstrap.sh'],{encoding:'utf8'});
  assert.equal(syntax.status,0,syntax.stderr);
  const fixture = path.join(root, 'checkout');
  fs.mkdirSync(path.join(fixture, 'deploy'), {recursive:true});
  fs.mkdirSync(path.join(root, 'bin'));
  const installed = path.join(root,'installed');
  fs.mkdirSync(installed);
  const installedBinary=path.join(installed,'moonhub-runner');
  const installedUnit=path.join(installed,'moonhub-runner-controller.service');
  fs.writeFileSync(path.join(fixture,'deploy/production.sh'), fs.readFileSync('deploy/production.sh','utf8')
    .replaceAll('/etc/systemd/system/',installed+'/')
    .replaceAll('/usr/local/bin/moonhub-runner',installedBinary));
  for (const name of ['production-provider-state.cjs','production-readiness.cjs','controller-unit.py']) {
    fs.copyFileSync('deploy/'+name,path.join(fixture,'deploy',name));
  }
  fs.writeFileSync(path.join(fixture,'deploy/deploy.sh'),`#!${process.execPath}
const fs=require('node:fs'),{DatabaseSync}=require('node:sqlite');
fs.appendFileSync(process.env.TEST_LOG,JSON.stringify(['web-upgrade'])+String.fromCharCode(10));
const db=new DatabaseSync(process.env.TEST_DB);
require('node:assert/strict').equal(db.prepare('SELECT COUNT(*) AS count FROM pipeline_provider WHERE paused=0').get().count,0);
db.close();
if(process.env.TEST_WEB_FAIL==='1')process.exit(9);
`,{mode:0o755});
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
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const a=process.argv.slice(2);fs.appendFileSync(process.env.TEST_LOG,JSON.stringify(a)+String.fromCharCode(10));
if(a[0]==='image'){if(fs.existsSync(process.env.TEST_BUILT))console.log(process.env.TEST_REVISION);else process.exit(1);}
else if(a[0]==='info')console.log('linux/x86_64');
else if(a[0]==='inspect')process.exit(1);
else if(a[0]==='create')console.log('controller-extract');
else if(a[0]==='cp'){fs.writeFileSync(a[2],process.env.TEST_CONTROLLER || 'controller');}
else if(a[0]==='login'){fs.readFileSync(0);}
else if(a[0]==='exec' && a.includes('node')){
 const at=a.indexOf('node');
 if(a.includes('restore') && process.env.TEST_RESTORE_FAIL==='1')process.exit(8);
 const r=spawnSync(process.execPath,a.slice(at+1),{input:fs.readFileSync(0),env:{...process.env,DB_PATH:process.env.TEST_DB}});
 process.stdout.write(r.stdout);process.stderr.write(r.stderr);process.exit(r.status ?? 1);
}
else if(a[0]==='buildx' && a[1]==='bake'){
 const b=JSON.parse(fs.readFileSync(a[a.indexOf('--file')+1]));
 assert.ok(a.includes('--allow=fs.read='+b.target.web.context));
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
  const upgradeFile=path.join(root,'upgrade.db');
  const upgradeDb=new DatabaseSync(upgradeFile);
  upgradeDb.exec(`CREATE TABLE pipeline_job_attempt(status TEXT);
    CREATE TABLE pipeline_worker(state TEXT,provider_id INTEGER);
    CREATE TABLE pipeline_provider(id INTEGER PRIMARY KEY,name TEXT,repository_scope TEXT,revoked INTEGER,paused INTEGER,mode TEXT,config_revision INTEGER,applied_revision INTEGER);
    INSERT INTO pipeline_provider VALUES(1,'asg','all',0,0,'asg',1,1),(2,'dind','all',0,0,'docker',1,1);
    INSERT INTO pipeline_worker VALUES('ready',1),('ready',2);`);
  const serviceState=path.join(root,'service-active');
  const controllerState=path.join(root,'controller-state');
  fs.mkdirSync(controllerState);
  fs.writeFileSync(path.join(controllerState,'registered.json'),'{}');
  fs.writeFileSync(installedBinary,'controller');
  const upgradeEnv={...process.env,PATH:path.join(root,'bin')+':'+process.env.PATH,
    TEST_DB:upgradeFile,TEST_LOG:log,TEST_BUILT:marker,TEST_REVISION:revision,TEST_SERVICE_STATE:serviceState,
    MOONHUB_PRODUCTION_LOCK_DIR:path.join(root,'lock'),MOONHUB_BACKUP_DIR:path.join(root,'backups'),
    MOONHUB_AWS_CLI:path.join(root,'bin/aws'),MOONHUB_CONTROLLER_STATE_DIR:controllerState,
    MOONHUB_REGISTRATION_TOKEN_FILE:path.join(root,'registration'),MOONHUB_SERVER:'https://example.invalid',
    MOONHUB_AWS_REGION:'us-west-2',MOONHUB_ASG:'on',MOONHUB_SPOT_ASG:'spot',
    MOONHUB_LAUNCH_TEMPLATE:'lt-test',MOONHUB_INSTANCE_TYPES:'m6a.large',MOONHUB_PARAMETER_PREFIX:'/moonhub-runner/test',
    MOONHUB_TASK_IMAGE:'registry/previous:commit',MOONHUB_PRODUCTION_DRAIN_TIMEOUT:'0'};
  const rendered=spawnSync('python3',['deploy/controller-unit.py'],{env:upgradeEnv,encoding:'utf8'});
  assert.equal(rendered.status,0,rendered.stderr);fs.writeFileSync(installedUnit,rendered.stdout);
  fs.writeFileSync(path.join(root,'bin/systemctl'),`#!${process.execPath}
const fs=require('node:fs'),a=process.argv.slice(2);
fs.appendFileSync(process.env.TEST_LOG,JSON.stringify(['systemctl',...a])+String.fromCharCode(10));
if(a[0]==='show')console.log(fs.existsSync(process.env.TEST_SERVICE_STATE)?fs.readFileSync(process.env.TEST_SERVICE_STATE,'utf8'):'inactive');
if(a[0]==='stop')fs.rmSync(process.env.TEST_SERVICE_STATE,{force:true});
if(a[0]==='start'||a[0]==='restart')fs.writeFileSync(process.env.TEST_SERVICE_STATE,'active');
`,{mode:0o755});
  fs.writeFileSync(path.join(root,'bin/aws'),`#!${process.execPath}
const fs=require('node:fs'),{DatabaseSync}=require('node:sqlite'),a=process.argv.slice(2);
fs.appendFileSync(process.env.TEST_LOG,JSON.stringify(['aws',...a])+String.fromCharCode(10));
if(a[0]==='ecr')console.log('fake-registry-password');
else if(a[0]==='autoscaling'){
 console.log(JSON.stringify({AutoScalingGroups:['on','spot'].map(name=>({AutoScalingGroupName:name,DesiredCapacity:process.env.TEST_ASG_BUSY==='1'?1:0,Instances:process.env.TEST_ASG_BUSY==='1'?[{InstanceId:'idle'}]:[]}))}));
}
`,{mode:0o755});
  function runUpgrade(extra={}) {
    fs.writeFileSync(log,'');
    if(extra.TEST_SERVICE_INACTIVE==='1')fs.rmSync(serviceState,{force:true});
    else fs.writeFileSync(serviceState,extra.TEST_SERVICE_ACTIVATING==='1'?'activating':'active');
    const result=spawnSync('bash',['deploy/production.sh','upgrade'],{cwd:fixture,env:{...upgradeEnv,...extra},encoding:'utf8',timeout:10000});
    return {...result,calls:fs.readFileSync(log,'utf8').trim().split(String.fromCharCode(10)).filter(Boolean).map(JSON.parse)};
  }
  const paused=()=>upgradeDb.prepare('SELECT paused FROM pipeline_provider WHERE id=1').get().paused;
  let upgraded=runUpgrade({TEST_ASG_BUSY:'1'});
  assert.equal(upgraded.status,0,upgraded.stderr);
  assert.equal(paused(),0,'successful upgrade left provider paused');
  assert.ok(upgraded.calls.some(a=>a[0]==='web-upgrade'));
  assert.ok(!upgraded.calls.some(a=>a[0]==='aws'&&a[1]==='autoscaling'),'unchanged controller required zero ASGs');
  assert.equal(upgradeDb.prepare('SELECT paused FROM pipeline_provider WHERE id=2').get().paused,0,'secondary provider left paused');
  const pauseIndex=upgraded.calls.findIndex(a=>a.includes('pause-all'));
  assert.ok(pauseIndex>upgraded.calls.findIndex(a=>a[0]==='push'),'paused claims during image publication');
  assert.ok(pauseIndex>upgraded.calls.findIndex(a=>a[0]==='systemctl'&&a[1]==='stop'),'temporary pause retired idle workers');
  assert.ok(upgraded.calls.findIndex(a=>a.includes('restore'))<upgraded.calls.findIndex(a=>a[0]==='systemctl'&&a[1]==='start'));
  assert.ok(fs.existsSync(serviceState));
  upgraded=runUpgrade({TEST_SERVICE_INACTIVE:'1'});
  assert.equal(upgraded.status,0,upgraded.stderr);
  assert.ok(fs.existsSync(serviceState),'successful upgrade left controller stopped');
  upgradeDb.exec('UPDATE pipeline_provider SET paused=1');
  upgraded=runUpgrade();assert.equal(upgraded.status,0,upgraded.stderr);assert.equal(paused(),1,'upgrade resumed an operator-paused provider');
  upgradeDb.exec('UPDATE pipeline_provider SET paused=0');
  upgraded=runUpgrade({TEST_WEB_FAIL:'1'});
  assert.notEqual(upgraded.status,0);assert.equal(paused(),0,'Web switch failure left provider paused');
  assert.equal(upgradeDb.prepare('SELECT paused FROM pipeline_provider WHERE id=2').get().paused,0,'failed switch left Docker paused');
  assert.ok(fs.existsSync(serviceState),'failure did not restart controller');
  upgradeDb.exec("INSERT INTO pipeline_job_attempt VALUES('running')");
  upgraded=runUpgrade({TEST_SERVICE_ACTIVATING:'1'});assert.notEqual(upgraded.status,0);assert.equal(paused(),0);
  assert.equal(fs.readFileSync(serviceState,'utf8'),'active','failed upgrade cancelled the controller restart timer');
  assert.ok(!upgraded.calls.some(a=>a[0]==='web-upgrade'));
  upgradeDb.exec("DELETE FROM pipeline_job_attempt; UPDATE pipeline_worker SET state='busy' WHERE provider_id=2");
  upgraded=runUpgrade();assert.notEqual(upgraded.status,0);assert.equal(paused(),0);
  assert.ok(!upgraded.calls.some(a=>a[0]==='web-upgrade'),'switched while Docker cleanup was busy');
  fs.writeFileSync(path.join(root,'bin/sleep'),`#!${process.execPath}
const fs=require('node:fs'),{DatabaseSync}=require('node:sqlite');
fs.appendFileSync(process.env.TEST_LOG,JSON.stringify(['wait-cleanup'])+String.fromCharCode(10));
const db=new DatabaseSync(process.env.TEST_DB);db.exec("UPDATE pipeline_worker SET state='ready'");db.close();
`,{mode:0o755});
  upgraded=runUpgrade({MOONHUB_PRODUCTION_DRAIN_TIMEOUT:'5'});
  assert.equal(upgraded.status,0,upgraded.stderr);
  assert.ok(upgraded.calls.some(a=>a[0]==='wait-cleanup'),'did not wait for worker cleanup');
  assert.ok(upgraded.calls.findIndex(a=>a[0]==='wait-cleanup') < upgraded.calls.findIndex(a=>a[0]==='web-upgrade'));
  assert.equal(upgradeDb.prepare('SELECT paused FROM pipeline_provider WHERE id=2').get().paused,0);
  upgradeDb.exec("UPDATE pipeline_worker SET state='ready'");
  upgraded=runUpgrade({TEST_CONTROLLER:'changed'});
  assert.notEqual(upgraded.status,0,'updated controller bypassed undrained workers');assert.equal(paused(),0);
  assert.ok(!upgraded.calls.some(a=>a[0]==='web-upgrade'));
  upgradeDb.exec("UPDATE pipeline_worker SET state='drained' WHERE provider_id=1");
  upgraded=runUpgrade({TEST_CONTROLLER:'changed',TEST_ASG_BUSY:'1'});
  assert.notEqual(upgraded.status,0,'updated controller bypassed nonzero ASGs');assert.equal(paused(),0);
  upgraded=runUpgrade({TEST_CONTROLLER:'changed'});
  assert.equal(upgraded.status,0,upgraded.stderr);assert.equal(paused(),0);
  assert.ok(upgraded.calls.some(a=>a[0]==='systemctl'&&a[1]==='restart'));
  upgraded=runUpgrade({TEST_RESTORE_FAIL:'1'});
  assert.notEqual(upgraded.status,0,'reported success when restoring pause failed');
  assert.match(upgraded.stderr,/recovery journal:/);assert.equal(paused(),1);
  const journals=fs.readdirSync(upgradeEnv.MOONHUB_BACKUP_DIR).filter(n=>n.startsWith('controller-'));
  assert.ok(journals.some(n=>fs.existsSync(path.join(upgradeEnv.MOONHUB_BACKUP_DIR,n,'provider-state.json'))));
  upgradeDb.close();
  console.log('Production deployment: atomic pause/restore, idle-worker switch, strict controller drain, failure recovery, safe unit and builds passed.');
} finally { fs.rmSync(root,{recursive:true,force:true}); }
