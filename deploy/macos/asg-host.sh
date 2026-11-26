#!/bin/bash
# Root-owned entry point on the dedicated Apple Silicon EC2 host.
set -euo pipefail
umask 077
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
[[ $(uname -s) = Darwin && $(uname -m) = arm64 && $(id -u) = 0 ]]

state=/var/lib/moonhub-macos-asg
home=$state/home
private=$state/private
bootstrap=$private/bootstrap.json
workspace=$state/workspace
tart=/usr/local/lib/moonhub-macos-asg/tart.app/Contents/MacOS/tart
runner=/usr/local/lib/moonhub-macos-asg/runner/moonhub-runner
service=io.moonhub.macos-asg-worker
ssm=system/com.amazon.aws.ssm
mode=${1:-}

if [[ "$mode" = bootstrap ]]; then
  [[ $# = 3 && "$2" =~ ^[a-z0-9-]+$ && "$3" =~ ^/moonhub-runner/[a-zA-Z0-9_/-]+/i-[a-f0-9]+$ ]]
  [[ -x "$runner" && -x "$tart" && -x /usr/local/lib/moonhub-macos-asg/bin/softnet && -d "$home/tart/vms" ]]
  if /bin/launchctl print "system/$service" >/dev/null 2>&1; then exit 0; fi
  [[ ! -e "$workspace/ci-consumed" ]]
  pending=$(mktemp "$private/bootstrap.XXXXXX")
  trap 'rm -f "$pending"' EXIT
  /usr/bin/env -i PATH="$PATH" HOME="$home" \
    AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    aws ssm get-parameter --region "$2" --name "$3" --with-decryption \
    --query Parameter.Value --output text --no-cli-pager > "$pending"
  [[ -s "$pending" ]]
  mv -f "$pending" "$bootstrap"
  /bin/launchctl bootstrap system /usr/local/lib/moonhub-macos-asg/asg-worker.plist
  exit 0
fi

[[ "$mode" = worker && $# = 1 && -f "$bootstrap" && ! -L "$bootstrap" ]]
# LaunchDaemon lives outside the SSM session. Wait until the outside controller
# cuts IMDS before stopping the agent, then wait for the separate server gate.
for ((attempt = 0; attempt < 120; attempt++)); do
  if ! /usr/bin/curl --noproxy '*' -fsS --max-time 1 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" != 119 ]] || exit 125
  sleep 1
done
if /bin/launchctl print "$ssm" >/dev/null 2>&1; then
  /bin/launchctl bootout "$ssm"
fi
! /bin/launchctl print "$ssm" >/dev/null 2>&1 || exit 125

# Virtualization.framework needs a login keychain even on a headless host.
# This per-instance keychain is created after boot and holds no operator secrets.
export HOME=$home TART_HOME=$home/tart
keychain=$home/Library/Keychains/moonhub.keychain-db
if [[ ! -f "$keychain" ]]; then
  /usr/bin/security create-keychain -p '' "$keychain"
fi
/usr/bin/security unlock-keychain -p '' "$keychain"
/usr/bin/security login-keychain -s "$keychain"
exec "$runner" worker --bootstrap-file "$bootstrap" --workspace-root "$workspace" \
  --tart "$tart" --tart-home "$TART_HOME" --prepare-timeout 240
