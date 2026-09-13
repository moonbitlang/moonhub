#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD
tmp=$(mktemp -d "${TMPDIR:-/tmp}/moonhub-smoke.XXXXXXXX")
project="moonhub-smoke-$(date +%s)-$$"
export MOONHUB_SMOKE_SECRET="$tmp/root_password"
export MOONHUB_SSH_IMPORT_DIR="$tmp/ssh-import"
mkdir -p "$MOONHUB_SSH_IMPORT_DIR"
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
    in_status = False
    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if sys.argv[1] == "csrf" and tag == "input" and attributes.get("name") == "csrf_token":
            self.value = attributes.get("value")
        if sys.argv[1] == "revoke" and tag == "a":
            href = attributes.get("href", "")
            if href.startswith("/settings/ssh-keys/") and href.endswith("/revoke"):
                self.value = href
        if sys.argv[1] == "status" and tag == "p" and "repository-job-state" in attributes.get("class", ""):
            self.in_status = True
    def handle_endtag(self, tag):
        if tag == "p":
            self.in_status = False
    def handle_data(self, data):
        if self.in_status:
            self.value = data

parser = SettingsParser()
parser.feed(sys.stdin.read())
if not parser.value:
    raise SystemExit("missing SSH settings form value")
print(parser.value)
' "$1"
}

wait_repository_operation() {
  local name=$1 expected=$2 code state
  for _ in $(seq 1 60); do
    code=$(curl --silent --show-error --output "$tmp/operation" --write-out '%{http_code}' \
      -b "$tmp/cookies" "$http/teams/smoke-team/repositories/$name/status")
    if [ "$code" = 303 ] && [ "$expected" = Ready ]; then return; fi
    if [ "$code" = 200 ]; then
      state=$(settings_value status < "$tmp/operation")
      if [ "$state" = "$expected" ]; then return; fi
      if [ "$state" = Failed ]; then
        printf 'Repository operation failed: %s\n' "$name" >&2
        cat "$tmp/operation" >&2
        return 1
      fi
    fi
    sleep 1
  done
  printf 'Repository operation did not reach %s: %s\n' "$expected" "$name" >&2
  return 1
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
curl --fail --silent --show-error -b "$tmp/cookies" "$http/admin/settings/ssh" > "$tmp/settings"
csrf=$(settings_value csrf < "$tmp/settings")
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" -d 'host=127.0.0.1' \
  --data-urlencode "port=$ssh_port" "$http/admin/settings/ssh")
test "$status" = 303
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
grep -Fq "$url" "$tmp/response"
if grep -Fq 'ssh://git@ssh:2222' "$tmp/response"; then
  printf '%s\n' 'Clone UI exposed a container-internal endpoint' >&2
  exit 1
fi
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

# Team creation and an empty repository are exercised through their web forms.
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" -d 'name_key=smoke-team&display_name=Smoke%20Team' "$http/teams")
test "$status" = 303
curl --fail --silent --show-error -b "$tmp/cookies" "$http/teams/smoke-team/repositories/new" > "$tmp/settings"
csrf=$(settings_value csrf < "$tmp/settings")
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" -d 'name=empty&visibility=private' \
  "$http/teams/smoke-team/repositories")
test "$status" = 303
wait_repository_operation empty Ready
curl --fail --silent --show-error -b "$tmp/cookies" "$http/smoke-team/empty" > "$tmp/response"
grep -q 'No files.' "$tmp/response"

git -C "$tmp/source" branch feature/import
git -C "$tmp/source" tag import-v1
git -C "$tmp/source" push origin feature/import import-v1
ssh-keygen -q -t ed25519 -N '' -f "$tmp/import-key"
curl --fail --silent --show-error -b "$tmp/cookies" "$http/settings/ssh-keys/new" > "$tmp/settings"
csrf=$(settings_value csrf < "$tmp/settings")
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" --data-urlencode 'title=Import source access' \
  --data-urlencode "public_key@$tmp/import-key.pub" "$http/settings/ssh-keys")
test "$status" = 303
mkdir -p "$MOONHUB_SSH_IMPORT_DIR/smoke-team"
cp "$tmp/import-key" "$MOONHUB_SSH_IMPORT_DIR/smoke-team/id_ed25519"
printf '%s\n' 'ssh:2222' > "$MOONHUB_SSH_IMPORT_DIR/smoke-team/allowed_hosts"
# Deliberately pin the wrong public key first; importing must fail closed.
awk '{print "[ssh]:2222 " $1 " " $2}' "$tmp/import-key.pub" > "$MOONHUB_SSH_IMPORT_DIR/smoke-team/known_hosts"
"${compose[@]}" restart web
"${compose[@]}" up --no-build -d --wait --wait-timeout 180
refresh_endpoints
curl --fail --silent --show-error -b "$tmp/cookies" "$http/teams/smoke-team/repositories/import" > "$tmp/settings"
csrf=$(settings_value csrf < "$tmp/settings")
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" -d 'name=blocked&source_url=git@unlisted.example:repo.git' \
  "$http/teams/smoke-team/repositories/import")
test "$status" = 400
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" -d 'name=imported&visibility=private' \
  --data-urlencode "source_url=$url" "$http/teams/smoke-team/repositories/import")
test "$status" = 303
wait_repository_operation imported Failed
grep -Eq 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' "$tmp/operation"
if git ls-remote "ssh://git@127.0.0.1:$ssh_port/smoke-team/imported.git" > "$tmp/denied" 2>&1; then
  printf '%s\n' 'An incomplete import was exposed over SSH' >&2
  exit 1
fi
# Read the source host key through its trusted container console, not TOFU.
"${compose[@]}" exec -T ssh cat /var/lib/moonhub/ssh/ssh_host_ed25519_key.pub > "$tmp/source-host.pub"
awk '{print "[ssh]:2222 " $1 " " $2}' "$tmp/source-host.pub" > "$MOONHUB_SSH_IMPORT_DIR/smoke-team/known_hosts"
"${compose[@]}" restart web
"${compose[@]}" up --no-build -d --wait --wait-timeout 180
refresh_endpoints
curl --fail --silent --show-error -b "$tmp/cookies" "$http/teams/smoke-team/repositories/imported/status" > "$tmp/settings"
csrf=$(settings_value csrf < "$tmp/settings")
status=$(curl --silent --show-error --output "$tmp/response" --write-out '%{http_code}' \
  -b "$tmp/cookies" --data-urlencode "csrf_token=$csrf" "$http/teams/smoke-team/repositories/imported/retry")
test "$status" = 303
wait_repository_operation imported Ready
import_url="ssh://git@127.0.0.1:$ssh_port/smoke-team/imported.git"
git ls-remote "$url" > "$tmp/source-refs"
git ls-remote "$import_url" > "$tmp/imported-refs"
cmp "$tmp/source-refs" "$tmp/imported-refs"
git clone --quiet "$import_url" "$tmp/imported"
cmp "$tmp/source/binary.dat" "$tmp/imported/binary.dat"
test "$(git -C "$tmp/imported" symbolic-ref --short HEAD)" = main
test -z "$("${compose[@]}" exec -T --user git web git --git-dir=/data/repos/smoke-team/imported.git remote)"

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
printf '%s\n' 'Docker SSH smoke test passed: web key management, team repositories, SSH import, host verification, retry, refs, persistence, revocation.'
