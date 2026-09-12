#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD
tmp=$(mktemp -d "${TMPDIR:-/tmp}/moonhub-smoke.XXXXXXXX")
project="moonhub-smoke-$(date +%s)-$$"
export MOONHUB_SMOKE_SECRET="$tmp/root_password"
printf '%s\n' 'bootstrapSmokePassword123' > "$MOONHUB_SMOKE_SECRET"
chmod 600 "$MOONHUB_SMOKE_SECRET"
compose=(docker compose --env-file /dev/null --project-name "$project"
  -f "$repo/compose.yaml" -f "$repo/deploy/compose.smoke.yaml")

cleanup() {
  result=$?
  trap - EXIT
  if [ "$result" -ne 0 ]; then
    "${compose[@]}" logs --no-color --tail 100 || true
  fi
  if [ -S "$tmp/control" ]; then
    ssh -S "$tmp/control" -O exit git@127.0.0.1 >/dev/null 2>&1 || true
  fi
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$result"
}
trap cleanup EXIT
trap 'printf "Smoke test failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

refresh_endpoints() {
  http_address=$("${compose[@]}" port web 8080)
  ssh_address=$("${compose[@]}" port ssh 2222)
  ssh_port=${ssh_address##*:}
  http="http://$http_address"
  url="ssh://git@127.0.0.1:$ssh_port/root/demo.git"
  ssh_opts=(-F /dev/null -i "$tmp/key" -p "$ssh_port" -o IdentitiesOnly=yes
    -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$tmp/known_hosts")
}

settings_value() {
  python3 -c '
import sys
from html.parser import HTMLParser

class SettingsParser(HTMLParser):
    value = None
    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if sys.argv[1] == "csrf" and tag == "input" and attributes.get("name") == "csrf_token":
            self.value = attributes.get("value")
        if sys.argv[1] == "revoke" and tag == "a":
            href = attributes.get("href", "")
            if href.startswith("/settings/ssh-keys/") and href.endswith("/revoke"):
                self.value = href

parser = SettingsParser()
parser.feed(sys.stdin.read())
if not parser.value:
    raise SystemExit("missing SSH settings form value")
print(parser.value)
' "$1"
}

if [ "${MOONHUB_SMOKE_SKIP_BUILD:-0}" != 1 ]; then
  "${compose[@]}" build web
fi
"${compose[@]}" up --no-build -d --wait --wait-timeout 180
refresh_endpoints

status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -c "$tmp/cookies" -d 'name_key=root&password=bootstrapSmokePassword123' "$http/login")
test "$status" = 303
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" -c "$tmp/cookies" \
  -d 'new_password=activatedSmokePassword123&confirm_password=activatedSmokePassword123' "$http/change-password")
test "$status" = 303

ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
curl --fail --silent --show-error -b "$tmp/cookies" "$http/settings/ssh-keys/new" > "$tmp/settings"
csrf=$(settings_value csrf < "$tmp/settings")
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" --data-urlencode 'title=Smoke' \
  --data-urlencode "public_key@$tmp/key.pub" "$http/settings/ssh-keys")
test "$status" = 303
curl --fail --silent --show-error -b "$tmp/cookies" "$http/settings/ssh-keys" > "$tmp/settings"
revoke_path=$(settings_value revoke < "$tmp/settings")
"${compose[@]}" exec -T --user git web moonhub repo-create root/demo
curl --fail --silent --show-error -b "$tmp/cookies" "$http/root/demo" > "$tmp/response"
grep -q 'No files.' "$tmp/response"
ssh-keyscan -t ed25519 -T 5 -p "$ssh_port" 127.0.0.1 > "$tmp/known_hosts" 2>/dev/null
export GIT_SSH_COMMAND="ssh -F /dev/null -i '$tmp/key' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$tmp/known_hosts'"
ssh "${ssh_opts[@]}" -T git@127.0.0.1
GIT_TRACE_PACKET="$tmp/packets" git -c protocol.version=2 ls-remote "$url"
grep -q 'version 2' "$tmp/packets"

git init --quiet --initial-branch=main "$tmp/source"
git -C "$tmp/source" config user.name 'Smoke Test'
git -C "$tmp/source" config user.email 'smoke@example.com'
dd if=/dev/urandom of="$tmp/source/binary.dat" bs=1024 count=4096 2>/dev/null
printf '%s\n' 'SSH deployment smoke test' > "$tmp/source/README.md"
git -C "$tmp/source" add .
git -C "$tmp/source" commit --quiet -m 'Initial smoke commit'
git -C "$tmp/source" remote add origin "$url"
git -C "$tmp/source" push origin main
git -c protocol.version=2 clone --quiet "$url" "$tmp/clone"
cmp "$tmp/source/binary.dat" "$tmp/clone/binary.dat"
printf '%s\n' 'Updated over SSH' >> "$tmp/source/README.md"
git -C "$tmp/source" commit --quiet -am 'Second smoke commit'
git -C "$tmp/source" push origin main
git -C "$tmp/clone" fetch --quiet
test "$(git -C "$tmp/source" rev-parse HEAD)" = "$(git -C "$tmp/clone" rev-parse origin/main)"
curl --fail --silent --show-error -b "$tmp/cookies" "$http/root/demo" > "$tmp/response"
grep -q 'README.md' "$tmp/response"

for command in "id" "git-upload-pack '../demo.git'" "git-upload-pack 'root/demo.git'; id"; do
  # Pass deliberately invalid remote commands to the forced-command parser.
  # shellcheck disable=SC2029
  if ssh "${ssh_opts[@]}" git@127.0.0.1 "$command" > "$tmp/denied" 2>&1; then
    printf 'Unexpectedly accepted SSH command: %s\n' "$command" >&2
    exit 1
  fi
done
if ssh "${ssh_opts[@]}" -o ExitOnForwardFailure=yes -R 0:127.0.0.1:8080 git@127.0.0.1 > "$tmp/denied" 2>&1; then
  printf '%s\n' 'Unexpectedly allowed SSH forwarding' >&2
  exit 1
fi
ssh-keygen -q -t ed25519 -N '' -f "$tmp/unknown"
if ssh -F /dev/null -i "$tmp/unknown" -p "$ssh_port" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$tmp/known_hosts" git@127.0.0.1 > "$tmp/denied" 2>&1; then
  printf '%s\n' 'Unexpectedly accepted an unregistered key' >&2
  exit 1
fi

"${compose[@]}" restart web ssh
"${compose[@]}" up --no-build -d --wait --wait-timeout 180
refresh_endpoints
ssh-keyscan -t ed25519 -T 5 -p "$ssh_port" 127.0.0.1 > "$tmp/known_hosts_after" 2>/dev/null
ssh-keygen -lf "$tmp/known_hosts" | awk '{ print $2 }' > "$tmp/host_key_before"
ssh-keygen -lf "$tmp/known_hosts_after" | awk '{ print $2 }' > "$tmp/host_key_after"
diff -u "$tmp/host_key_before" "$tmp/host_key_after"
cp "$tmp/known_hosts_after" "$tmp/known_hosts"
git ls-remote "$url" > "$tmp/refs"
grep -q refs/heads/main "$tmp/refs"
curl --fail --silent --show-error -b "$tmp/cookies" "$http/root/demo" > /dev/null

# Revocation must also reject a new channel on an already authenticated connection.
ssh "${ssh_opts[@]}" -M -S "$tmp/control" -fN git@127.0.0.1
curl --fail --silent --show-error -b "$tmp/cookies" "$http$revoke_path" > "$tmp/settings"
csrf=$(settings_value csrf < "$tmp/settings")
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" "$http$revoke_path")
test "$status" = 303
if ssh "${ssh_opts[@]}" -S "$tmp/control" git@127.0.0.1 "git-upload-pack 'root/demo.git'" > "$tmp/denied" 2>&1; then
  printf '%s\n' 'Revoked key opened a new channel on an existing connection' >&2
  exit 1
fi
if git ls-remote "$url" > "$tmp/denied" 2>&1; then
  printf '%s\n' 'Revoked key authenticated a new connection' >&2
  exit 1
fi
printf '%s\n' 'Docker SSH smoke test passed: web key management, push, clone, fetch, binary data, restrictions, persistence, revocation.'
