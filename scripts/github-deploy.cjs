const fs = require('node:fs');
const { execFileSync } = require('node:child_process');

async function deploy({ env = process.env, aws = callAws, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), log = console.log } = {}) {
  const revision = env.GITHUB_SHA;
  const instance = env.MOONHUB_DEPLOY_INSTANCE_ID;
  const document = env.MOONHUB_DEPLOY_DOCUMENT;
  if (!/^[0-9a-f]{40}$/.test(revision || '')) throw new Error('GITHUB_SHA must be a full commit SHA');
  if (!/^i-[0-9a-f]+$/.test(instance || '')) throw new Error('Missing/invalid deployment instance');
  if (document !== 'MoonHub-Deploy') throw new Error('Unexpected deployment document');
  const sent = aws(['ssm', 'send-command', '--instance-ids', instance, '--document-name', document,
    '--document-version', '1', '--parameters', JSON.stringify({ Revision: [revision] }),
    '--timeout-seconds', '600', '--comment', `GitHub master ${revision}`]);
  const commandId = sent.Command.CommandId;
  log(`SSM command ${commandId}; commit ${revision}`);
  // SSM's default CLI waiter stops after a few minutes. Builds can take longer.
  for (let poll = 0; poll < 300; poll++) {
    await sleep(15000);
    let result;
    try {
      result = aws(['ssm', 'get-command-invocation', '--command-id', commandId, '--instance-id', instance]);
    } catch (error) {
      if (String(error.stderr).includes('InvocationDoesNotExist')) continue;
      throw error;
    }
    if (['Pending', 'InProgress', 'Delayed'].includes(result.Status)) {
      if (poll % 4 === 0) log(`SSM ${commandId}: ${result.Status}`);
      continue;
    }
    log(result.StandardOutputContent || '');
    log(result.StandardErrorContent || '');
    if (result.Status !== 'Success') throw new Error(`SSM deployment ${commandId}: ${result.Status} (${result.ResponseCode})`);
    const marker = `MOONHUB_DEPLOY_OK:${revision}`;
    const skipped = `MOONHUB_DEPLOY_SKIPPED:${revision}`;
    if (!result.StandardOutputContent?.includes(marker) && !result.StandardOutputContent?.includes(skipped)) {
      throw new Error('SSM returned success without a deployment verification marker');
    }
    const outcome = result.StandardOutputContent.includes(marker) ? 'Deployed and verified' : 'Skipped superseded commit';
    if (env.GITHUB_STEP_SUMMARY) fs.appendFileSync(env.GITHUB_STEP_SUMMARY, `${outcome}: \`${revision}\`\n\nSSM command: \`${commandId}\`\n`);
    return result;
  }
  throw new Error(`Timed out waiting for SSM ${commandId}; inspect the command before retrying`);
}

function callAws(args) {
  return JSON.parse(execFileSync('aws', [...args, '--output', 'json', '--no-cli-pager'], {
    encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'pipe'],
  }));
}

module.exports = { deploy };
if (require.main === module) deploy().catch(error => { console.error(error.message); process.exitCode = 1; });
