const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {DatabaseSync} = require('node:sqlite');

test('DinD image retention survives repeated releases, retries and bounded storage', () => {
  const result=spawnSync('python3',['scripts/production-dind-images-test.py'],{encoding:'utf8'});
  assert.equal(result.status,0,result.stdout+result.stderr);
});

function fixture(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(),'moonhub-dind-state-'));
  const file = path.join(root,'test.db');
  const db = new DatabaseSync(file);
  try {
    db.exec(`CREATE TABLE pipeline_provider(id INTEGER PRIMARY KEY,name TEXT,mode TEXT,revoked INTEGER,paused INTEGER,config_json TEXT,config_revision INTEGER,observed_revision INTEGER,applied_revision INTEGER,control_status TEXT,controller_id TEXT,controller_until_ms INTEGER);
      CREATE TABLE pipeline_worker(provider_id INTEGER,state TEXT,draining INTEGER,worker_key TEXT,applied_revision INTEGER,last_seen_ms INTEGER);
      CREATE TABLE pipeline_job_attempt(provider_id INTEGER,status TEXT);
      INSERT INTO pipeline_provider VALUES(1,'dind','docker',0,1,'{"runner_image":"runner:old","cpus":"2","memory_mib":"3584"}',2,2,2,'applied','old',0);
      INSERT INTO pipeline_worker VALUES(1,'ready',0,'docker-old',2,0);`);
    const command = (...args) => spawnSync(process.execPath,['--no-warnings','deploy/production-dind-state.cjs',...args],{encoding:'utf8',env:{...process.env,DB_PATH:file}});
    const provider = () => db.prepare('SELECT * FROM pipeline_provider').get();
    run({db,command,provider});
  } finally {db.close();fs.rmSync(root,{recursive:true,force:true});}
}

test('stopped worker retirement requires paused claims and no active attempt', () => fixture(({db,command}) => {
  db.exec('UPDATE pipeline_provider SET paused=0');
  assert.notEqual(command('retire','dind').status,0);
  db.exec("UPDATE pipeline_provider SET paused=1;INSERT INTO pipeline_job_attempt VALUES(1,'running')");
  assert.notEqual(command('retire','dind').status,0);
  assert.equal(db.prepare('SELECT state FROM pipeline_worker').get().state,'ready');
  db.exec('DELETE FROM pipeline_job_attempt');
  const result=command('retire','dind');assert.equal(result.status,0,result.stderr);
  assert.equal(result.stdout.trim(),'old');
  assert.deepEqual({...db.prepare('SELECT state,draining FROM pipeline_worker').get()},{state:'drained',draining:1});
}));

test('saved current image is read without pausing claims or changing configuration', () => fixture(({db,command,provider}) => {
  db.exec('UPDATE pipeline_provider SET paused=0');
  const before=provider();
  const result=command('current-image','dind');
  assert.equal(result.status,0,result.stderr);
  assert.equal(result.stdout.trim(),'runner:old');
  assert.deepEqual(provider(),before);
}));

test('image upgrade and recovery preserve settings and monotonically advance revision', () => fixture(({db,command,provider}) => {
  const result=command('image','dind','runner:new');assert.equal(result.status,0,result.stderr);
  const journal=result.stdout.trim();
  assert.deepEqual(JSON.parse(journal),{id:'1',name:'dind',previous_image:'runner:old',installed_image:'runner:new'});
  assert.deepEqual(JSON.parse(provider().config_json),{runner_image:'runner:new',cpus:'2',memory_mib:'3584'});
  assert.equal(provider().config_revision,3);assert.equal(provider().control_status,'pending');
  assert.equal(command('image','dind','runner:new').status,0);assert.equal(provider().config_revision,3);
  db.exec(`UPDATE pipeline_provider SET config_json=json_set(config_json,'$.memory_mib','4096')`);
  assert.equal(command('restore-image','dind',journal).status,0);
  assert.deepEqual(JSON.parse(provider().config_json),{runner_image:'runner:old',cpus:'2',memory_mib:'4096'});
  assert.equal(provider().config_revision,4);
  assert.equal(command('restore-image','dind',journal).status,0);assert.equal(provider().config_revision,4);
  db.exec(`UPDATE pipeline_provider SET config_json=json_set(config_json,'$.runner_image','operator:changed')`);
  assert.notEqual(command('restore-image','dind',journal).status,0,'overwrote an operator image edit');
}));

test('verification requires a new live controller and a worker on the applied image', () => fixture(({db,command}) => {
  const verify=()=>command('verify','dind','runner:old','old');
  assert.notEqual(verify().status,0);
  db.prepare('UPDATE pipeline_provider SET controller_until_ms=?').run(Date.now()+60000);
  assert.notEqual(verify().status,0,'accepted the previous controller');
  db.exec("UPDATE pipeline_provider SET controller_id='new'");
  assert.equal(verify().status,0,'paused provider needs observation, without resuming claims');
  db.exec('UPDATE pipeline_provider SET paused=0');
  assert.notEqual(verify().status,0,'accepted an obsolete worker');
  db.prepare("UPDATE pipeline_worker SET worker_key='docker-new',last_seen_ms=?").run(Date.now());
  assert.equal(verify().status,0);
  db.exec('UPDATE pipeline_provider SET applied_revision=1');
  assert.notEqual(verify().status,0,'accepted unapplied image settings');
  db.exec('UPDATE pipeline_provider SET applied_revision=2;UPDATE pipeline_worker SET applied_revision=1');
  assert.notEqual(verify().status,0,'accepted a worker using the previous image');
  assert.equal(command('pause','dind').status,0);
  assert.equal(db.prepare('SELECT paused FROM pipeline_provider').get().paused,1);
}));

test('unit migration preserves hardening and rejects dynamic or ambiguous startup commands', () => {
  const result=spawnSync('python3',['-c',`
import importlib.util
s=importlib.util.spec_from_file_location('unit','deploy/controller-unit.py')
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
u='[Service]\\nExecStart=/private/bin/moonhub-runner run --server https://example.invalid --name dind --mode docker --state-dir /private/state --workspace-root /private/workspace --docker-host unix:///private/docker.sock --runner-image runner:old\\nMemoryMax=256M\\nCPUQuota=25%\\n'
v=m.render_docker(u,'runner:new')
assert m.docker_controller(v)[0]['runner_image']=='runner:new'
assert v.endswith('MemoryMax=256M\\nCPUQuota=25%\\n')
for bad in [u.replace('--mode docker','--mode asg'),u.replace('/private/state','$STATE'),u+'ExecStart=/bin/sh\\n',u.replace('--name dind','--name dind --name other')]:
 try: m.docker_controller(bad)
 except ValueError: pass
 else: raise AssertionError('accepted ambiguous or dynamic unit')
try: m.render_docker(u,'bad'+chr(10)+'ExecStart=/bin/sh')
except ValueError: pass
else: raise AssertionError('accepted a multiline image')
`],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
});
