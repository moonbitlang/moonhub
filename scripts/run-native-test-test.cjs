const assert = require('node:assert/strict');
const {test} = require('node:test');
const {verifyNativeResult, suspendWorkflowCommands} = require('./run-native-test.cjs');
const record = value => '----- BEGIN MOON TEST RESULT -----\n'+JSON.stringify(value)+'\n----- END MOON TEST RESULT -----\n';
const success = {type:'result',file:'acceptance.mbt',index:0,message:''};
test('native acceptance requires the result record, even when the process exits zero', () => {
  verifyNativeResult('task logs\n'+record({type:'start',file:'acceptance.mbt',index:0})+record(success),'acceptance.mbt');
  verifyNativeResult(record(success).replaceAll('\n','\r\n'),'acceptance.mbt');
  for(const output of ['',record({...success,message:'FAILED: actual != expected'}),record({...success,message:'skipped test'}),record({...success,file:'other.mbt'}),record({...success,index:1}),record(success)+record(success)]) {
    assert.throws(()=>verifyNativeResult(output,'acceptance.mbt'));
  }
});

test('nested Action commands are surrounded by unique stop and resume markers', () => {
  const tokens = [];
  for (let i = 0; i < 2; i++) {
    const writes = [];
    const resume = suspendWorkflowCommands(chunk => writes.push(chunk));
    const token = writes[0].match(/^::stop-commands::([a-f0-9-]+)\n$/)?.[1];
    assert.ok(token);
    tokens.push(token);
    const nested = '::add-matcher::C:/container/tsc.json\n::error::inner task diagnostic';
    writes.push(nested);
    resume();
    assert.deepEqual(writes, ['::stop-commands::' + token + '\n', nested, '\n::' + token + '::\n']);
  }
  assert.notEqual(tokens[0], tokens[1]);
});
