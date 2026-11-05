#!/bin/bash
# Run as root INSIDE a disposable Apple Silicon macOS template VM.
set -euo pipefail
[[ $(uname -s) = Darwin && $(uname -m) = arm64 && $(id -u) = 0 ]]
[[ $(sysctl -n kern.hv_vmm_present) = 1 ]] || { echo 'Refusing installation on a physical host' >&2; exit 1; }
BUNDLE=${1:?Usage: install-guest.sh /path/to/bundle}
[[ -x "$BUNDLE/bin/moonhub-runner" && -x "$BUNDLE/bin/moonhub-runner-step" && -x "$BUNDLE/bin/node" ]]
if ! id _moonhub >/dev/null 2>&1; then
  ! dscl . -search /Users UniqueID 599 | grep -q .
  ! dscl . -search /Groups PrimaryGroupID 599 | grep -q .
  dscl . -create /Groups/_moonhub PrimaryGroupID 599
  dscl . -create /Users/_moonhub
  dscl . -create /Users/_moonhub UniqueID 599
  dscl . -create /Users/_moonhub PrimaryGroupID 599
  dscl . -create /Users/_moonhub UserShell /usr/bin/false
  dscl . -create /Users/_moonhub NFSHomeDirectory /var/empty
  dscl . -create /Users/_moonhub IsHidden 1
fi
[[ " $(id -Gn _moonhub) " != *' admin '* ]]
mkdir -p /usr/local/bin /usr/local/lib/moonhub /usr/local/libexec /opt/actions/node20/bin
# Run the transport as a root LaunchDaemon so readiness never depends on GUI
# auto-login or the base image's public administrator password.
agent=/usr/local/lib/moonhub/tart-guest-agent
if [[ ! -x "$agent" ]]; then agent=$(command -v tart-guest-agent || true); fi
[[ -n "$agent" && -x "$agent" ]] || { echo 'Install Tart Guest Agent first' >&2; exit 1; }
cp -R "$BUNDLE/bin" "$BUNDLE/actions" "$BUNDLE/licenses" /usr/local/lib/moonhub/
cp "$BUNDLE/macos-guest.mjs" /usr/local/lib/moonhub/
cp "$BUNDLE/bin/moonhub-runner" "$BUNDLE/bin/moonhub-runner-step" /usr/local/bin/
# Keep bundled dylibs beside both executable copies.
shopt -s nullglob
for library in "$BUNDLE/lib/"*.dylib; do cp "$library" /usr/local/bin/; done
if [[ -d "$BUNDLE/lib" ]]; then cp -R "$BUNDLE/lib" /usr/local/lib/moonhub/; fi
ln -sf /usr/local/lib/moonhub/bin/node /usr/local/bin/node
cp "$BUNDLE/bin/node20" /opt/actions/node20/bin/node
cat > /usr/local/libexec/moonhub-macos-guest <<'WRAPPER'
#!/bin/sh
exec /usr/local/lib/moonhub/bin/node /usr/local/lib/moonhub/macos-guest.mjs "$@"
WRAPPER
chmod 755 /usr/local/libexec/moonhub-macos-guest
chown -R root:wheel /usr/local/lib/moonhub /usr/local/libexec/moonhub-macos-guest /usr/local/bin/moonhub-runner /usr/local/bin/moonhub-runner-step /opt/actions
chmod -R go-w /usr/local/lib/moonhub /opt/actions
mkdir -p '/Library/Application Support/MoonHub' /var/lib/moonhub-guest
[[ -z $(ls -A /var/lib/moonhub-guest) ]] || { echo 'Template already contains job state' >&2; exit 1; }
chown root:wheel '/Library/Application Support/MoonHub' /var/lib/moonhub-guest
chmod 755 '/Library/Application Support/MoonHub' /var/lib/moonhub-guest
printf '{"version":1}\n' > '/Library/Application Support/MoonHub/guest.json'
chown root:wheel '/Library/Application Support/MoonHub/guest.json'
chmod 644 '/Library/Application Support/MoonHub/guest.json'
if [[ "$agent" != /usr/local/lib/moonhub/tart-guest-agent ]]; then cp "$agent" /usr/local/lib/moonhub/tart-guest-agent; fi
chown root:wheel /usr/local/lib/moonhub/tart-guest-agent
chmod 755 /usr/local/lib/moonhub/tart-guest-agent
cat > /Library/LaunchDaemons/io.moonhub.guest-rpc.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>io.moonhub.guest-rpc</string><key>ProgramArguments</key><array><string>/usr/local/lib/moonhub/tart-guest-agent</string><string>--run-rpc</string></array><key>WorkingDirectory</key><string>/var/empty</string><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>
PLIST
chown root:wheel /Library/LaunchDaemons/io.moonhub.guest-rpc.plist
chmod 644 /Library/LaunchDaemons/io.moonhub.guest-rpc.plist
# The currently running transport remains until shutdown; next boot uses only
# the root RPC service. Remove the image's known login/sudo access before jobs.
rm -f /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
/usr/bin/defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true
rm -f /etc/kcpassword
# The public base image's admin user must not remain an escalation route.
if id admin >/dev/null 2>&1; then
  dseditgroup -o edit -d admin -t user admin
  pwpolicy -u admin -disableuser
fi
rm -f /etc/sudoers.d/admin
rm -f /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
launchctl disable system/com.openssh.sshd
launchctl disable system/com.apple.screensharing
/usr/local/libexec/moonhub-macos-guest health

# Ensure the prepared image survives an immediate VM stop/clone.
sync
