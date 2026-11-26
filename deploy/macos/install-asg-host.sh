#!/bin/bash
# Install only on the dedicated EC2 Mac AMI builder, after preparing the guest.
set -euo pipefail
umask 077
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
[[ $(uname -s) = Darwin && $(uname -m) = arm64 && $(id -u) = 0 ]]
[[ $(/usr/bin/sw_vers -productVersion) = 26.* ]]
[[ $(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null || printf '0') = 0 ]]
metadata=http://169.254.169.254/latest
token=$(/usr/bin/curl --noproxy '*' -fsS --max-time 3 -X PUT \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "$metadata/api/token")
instance_type=$(/usr/bin/curl --noproxy '*' -fsS --max-time 3 \
  -H "X-aws-ec2-metadata-token: $token" "$metadata/meta-data/instance-type")
unset token
[[ "$instance_type" = mac*.metal ]]

[[ $# = 4 ]] || { echo 'Usage: install-asg-host.sh BUNDLE TART_APP SOFTNET GUEST_EXPORT.tvm' >&2; exit 2; }
bundle=$1
tart_app=$2
softnet=$3
guest=$4
[[ -x "$bundle/bin/moonhub-runner" && -x "$tart_app/Contents/MacOS/tart" && -x "$softnet" && -s "$guest" ]]
[[ $("$tart_app/Contents/MacOS/tart" --version) = 2.41.1 && $("$softnet" --version) = 'softnet 0.26.0-816f07a' ]]
command -v aws >/dev/null
/bin/launchctl print system/com.amazon.aws.ssm >/dev/null

files=$(cd "$(dirname "$0")" && pwd)
runtime=/usr/local/lib/moonhub-macos-asg
state=/var/lib/moonhub-macos-asg
[[ ! -e "$runtime" && ! -e "$state" ]]
install -d -o root -g wheel -m 0755 "$runtime/runner" "$runtime/bin" /usr/local/libexec
/usr/bin/ditto "$tart_app" "$runtime/tart.app"
/usr/bin/ditto "$bundle/bin" "$runtime/runner"
chown -R root:wheel "$runtime"
chmod -R go-w "$runtime"
install -o root -g wheel -m 4755 "$softnet" "$runtime/bin/softnet"
install -o root -g wheel -m 0755 "$files/asg-host.sh" /usr/local/libexec/moonhub-macos-asg-host
install -d -o root -g wheel -m 0700 "$state" "$state/private" \
  "$state/workspace" "$state/home" "$state/home/Library/Keychains" "$state/home/tart"
export HOME=$state/home TART_HOME=$state/home/tart
"$runtime/tart.app/Contents/MacOS/tart" import "$guest" moonhub-macos-15
"$runtime/runner/moonhub-runner" worker --help >/dev/null
# Keep the unit outside LaunchDaemons in the baked image so it cannot start
# before SSM has staged this instance's credential. Bootstrap loads it directly.
install -o root -g wheel -m 0644 "$files/asg-worker.plist" "$runtime/asg-worker.plist"
/usr/bin/plutil -lint "$runtime/asg-worker.plist"
