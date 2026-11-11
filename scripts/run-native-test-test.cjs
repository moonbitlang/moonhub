const assert = require('node:assert/strict');
const {test} = require('node:test');
const {verifyNativeResult} = require('./run-native-test.cjs');
const record = value => '----- BEGIN MOON TEST RESULT -----\n'+JSON.stringify(value)+'\n----- END MOON TEST RESULT -----\n';
const success = {type:'result',file:'acceptance.mbt',index:0,message:''};
test('native acceptance requires the result record, even when the process exits zero', () => {
  verifyNativeResult('task logs\n'+record({type:'start',file:'acceptance.mbt',index:0})+record(success),'acceptance.mbt');
  verifyNativeResult(record(success).replaceAll('\n','\r\n'),'acceptance.mbt');
  for(const output of ['',record({...success,message:'FAILED: actual != expected'}),record({...success,message:'skipped test'}),record({...success,file:'other.mbt'}),record({...success,index:1}),record(success)+record(success)]) {
    assert.throws(()=>verifyNativeResult(output,'acceptance.mbt'));
  }
});
