const {spawn} = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const {randomUUID} = require('node:crypto');

function suspendWorkflowCommands(write) {
  const token = randomUUID();
  write('::stop-commands::' + token + '\n');
  // Start on a fresh line even if the last task log omitted its newline.
  return () => write('\n::' + token + '::\n');
}

function verifyNativeResult(output, file) {
  const records = [...output.matchAll(/----- BEGIN MOON TEST RESULT -----\r?\n([^\r\n]+)\r?\n----- END MOON TEST RESULT -----/g)]
    .map(match => JSON.parse(match[1]));
  const results = records.filter(record => record.type === 'result');
  if (results.length !== 1 || results[0].file !== file || results[0].index !== 0 || results[0].message !== '') {
    throw new Error('Native acceptance did not report exactly one successful test: ' + JSON.stringify(results));
  }
}

module.exports = {verifyNativeResult, suspendWorkflowCommands};
if (require.main === module) {
  const binary = process.argv[2], file = process.argv[3];
  if (!binary || !file || !fs.statSync(binary).isFile()) throw new Error('Pass a native test executable and test source filename');
  // Inner Actions may emit add-matcher or error commands containing paths that
  // exist only in the task container. They are plain logs to this outer runner.
  const resume = process.env.GITHUB_ACTIONS === 'true'
    ? suspendWorkflowCommands(chunk => process.stdout.write(chunk)) : () => {};
  const child = spawn(path.resolve(binary), [file + ':0-1'], {stdio:['ignore','pipe','inherit']});
  let output = '', overflow = false;
  child.stdout.on('data', chunk => {
    process.stdout.write(chunk);
    output += chunk;
    if (Buffer.byteLength(output) > 8388608) {overflow = true;child.kill('SIGKILL');}
  });
  child.on('error', error => {console.error(error.message);process.exitCode=1;});
  child.on('close', code => {
    try {
      if (code !== 0 || overflow) throw new Error('Native acceptance process failed or exceeded its output limit');
      verifyNativeResult(output, file);
    } catch(error) {console.error(error.message);process.exitCode=1;}
    finally {resume();}
  });
}
